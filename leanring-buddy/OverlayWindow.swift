//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    private var cursorAccentColor: Color {
        companionManager.overlayCursorColor
    }

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm teachy"

    private let navigationPointerPhrases = [
        "right here",
        "this one",
        "over here",
        "here ya go",
        "that one",
    ]

    private let navigationBubbleMaxWidth: CGFloat = 280
    private let screenEdgePadding: CGFloat = 12

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // User's live chalk outline while holding push-to-talk
            if companionManager.voiceState == .listening {
                ChalkStrokePathView(
                    points: liveMouseOutlineSwiftUIPoints,
                    closesPath: liveMouseOutlineSwiftUIPoints.count >= 8
                )
            }

            // Clicky's chalk draw from a [DRAW:...] model response
            if let drawInstruction = companionManager.activeScreenDrawInstruction,
               isDisplayFrameOnThisScreen(drawInstruction.displayFrame) {
                ScreenGridChalkDrawOverlayView(
                    drawInstruction: drawInstruction,
                    screenFrame: screenFrame,
                    onFinished: {
                        companionManager.clearActiveScreenDrawInstruction()
                    }
                )
            }

            // Soft chalk flash when a course goal verifies
            if let celebration = companionManager.courseSuccessCelebration {
                let celebrationDisplayFrame = celebration.displayFrame ?? screenFrame
                if isDisplayFrameOnThisScreen(celebrationDisplayFrame) {
                    CourseSuccessCelebrationOverlayView(
                        screenPoint: convertScreenPointToSwiftUICoordinates(celebration.screenPoint),
                        accentColor: cursorAccentColor,
                        onFinished: {
                            companionManager.courseSuccessCelebration = nil
                        }
                    )
                }
            }

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(cursorAccentColor)
                            .shadow(color: cursorAccentColor.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Beside-cursor video (Farza intro + teacher part clips)
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let credit = companionManager.besideCursorVideoCredit,
                       !credit.isEmpty,
                       companionManager.onboardingVideoOpacity > 0.05 {
                        Text(credit)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.72))
                            )
                            .padding(8)
                            .opacity(companionManager.onboardingVideoOpacity)
                    }
                }
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(cursorAccentColor)
                            .shadow(color: cursorAccentColor.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Soft presence while Teachy waits on your turn
            if isCursorOnThisScreen,
               let presenceText = companionManager.coursePresenceBubbleText,
               !presenceText.isEmpty {
                Text(presenceText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(cursorAccentColor.opacity(0.55), lineWidth: 1)
                            )
                    )
                    .fixedSize()
                    .position(x: cursorPosition.x + 10 + 70, y: cursorPosition.y + 22)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cursorPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .allowsHitTesting(false)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(8)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: navigationBubbleMaxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(cursorAccentColor)
                            .shadow(
                                color: cursorAccentColor.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(
                        clampedBubblePosition(
                            bubbleSize: navigationBubbleSize,
                            anchor: cursorPosition,
                            maxBubbleWidth: navigationBubbleMaxWidth
                        )
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Triangle()
                .fill(cursorAccentColor)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: cursorAccentColor, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(
                    buddyIsVisibleOnThisScreen
                        && (companionManager.voiceState == .idle
                            || companionManager.voiceState == .responding
                            || buddyNavigationMode != .followingCursor)
                        ? cursorOpacity : 0
                )
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                accentColor: cursorAccentColor
            )
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView(accentColor: cursorAccentColor)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }

            handlePendingElementNavigationIfNeeded()
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { _ in
            handlePendingElementNavigationIfNeeded()
        }
        .onChange(of: companionManager.detectedElementDisplayFrame) { _ in
            handlePendingElementNavigationIfNeeded()
        }
    }

    private func isDisplayFrameOnThisScreen(_ displayFrame: CGRect) -> Bool {
        let displayCenter = CGPoint(x: displayFrame.midX, y: displayFrame.midY)
        return screenFrame.contains(displayCenter)
            || framesApproximatelyEqual(displayFrame, screenFrame)
    }

    private func framesApproximatelyEqual(_ frameA: CGRect, _ frameB: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(frameA.origin.x - frameB.origin.x) <= tolerance
            && abs(frameA.origin.y - frameB.origin.y) <= tolerance
            && abs(frameA.width - frameB.width) <= tolerance
            && abs(frameA.height - frameB.height) <= tolerance
    }

    private func handlePendingElementNavigationIfNeeded() {
        guard buddyNavigationMode == .followingCursor,
              let screenLocation = companionManager.detectedElementScreenLocation,
              let displayFrame = companionManager.detectedElementDisplayFrame,
              isDisplayFrameOnThisScreen(displayFrame) else {
            return
        }

        startNavigatingToElement(screenLocation: screenLocation)
    }

    private var liveMouseOutlineSwiftUIPoints: [CGPoint] {
        companionManager.mouseOutlineTracker.liveOutlinePointsInGlobalCoordinates
            .filter { screenFrame.contains($0) }
            .map { convertScreenPointToSwiftUICoordinates($0) }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if let displayFrame = companionManager.detectedElementDisplayFrame,
               isDisplayFrameOnThisScreen(displayFrame) {
                // Keep the target screen's buddy visible while navigation is about to start.
                return true
            }
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// Keeps speech bubbles on-screen — flips left/up when they'd clip past an edge.
    private func clampedBubblePosition(
        bubbleSize: CGSize,
        anchor: CGPoint,
        maxBubbleWidth: CGFloat,
        offsetX: CGFloat = 10,
        offsetY: CGFloat = 18
    ) -> CGPoint {
        let effectiveBubbleWidth = min(bubbleSize.width, maxBubbleWidth)
        let effectiveBubbleHeight = bubbleSize.height

        var bubbleCenterX = anchor.x + offsetX + effectiveBubbleWidth / 2
        var bubbleCenterY = anchor.y + offsetY + effectiveBubbleHeight / 2

        let minX = screenEdgePadding + effectiveBubbleWidth / 2
        let maxX = screenFrame.width - screenEdgePadding - effectiveBubbleWidth / 2
        let minY = screenEdgePadding + effectiveBubbleHeight / 2
        let maxY = screenFrame.height - screenEdgePadding - effectiveBubbleHeight / 2

        if bubbleCenterX > maxX {
            bubbleCenterX = anchor.x - offsetX - effectiveBubbleWidth / 2
        }
        if bubbleCenterY > maxY {
            bubbleCenterY = anchor.y - offsetY - effectiveBubbleHeight / 2
        }

        bubbleCenterX = max(minX, min(bubbleCenterX, maxX))
        bubbleCenterY = max(minY, min(bubbleCenterY, maxY))

        return CGPoint(x: bubbleCenterX, y: bubbleCenterY)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        // Show the full coaching line immediately so it matches TTS (no mid-sentence cutoff).
        navigationBubbleText = pointerPhrase
        navigationBubbleScale = 1.0
        waitForSpeechThenFlyBackToCursor()
    }

    /// Holds the pointing bubble until Clicky finishes speaking (plus a short beat).
    private func waitForSpeechThenFlyBackToCursor() {
        let minimumHoldDeadline = Date().addingTimeInterval(1.2)

        func pollUntilReadyToFlyBack() {
            guard buddyNavigationMode == .pointingAtTarget else { return }

            let stillSpeaking = companionManager.voiceState == .responding
                || companionManager.voiceState == .processing
            let minimumHoldRemaining = minimumHoldDeadline.timeIntervalSinceNow > 0

            if stillSpeaking || minimumHoldRemaining {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    pollUntilReadyToFlyBack()
                }
                return
            }

            self.navigationBubbleOpacity = 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.startFlyingBackToCursor()
            }
        }

        pollUntilReadyToFlyBack()
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    let accentColor: Color

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accentColor)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: accentColor.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Chalk outline overlays (user mouse + Clicky draw)

private struct ChalkStrokePathView: View {
    let points: [CGPoint]
    let closesPath: Bool

    private let chalkColor = Color(red: 1.0, green: 0.92, blue: 0.35)

    var body: some View {
        ZStack {
            ChalkStrokeShape(points: points, closesPath: closesPath)
                .stroke(chalkColor.opacity(0.35), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))

            ChalkStrokeShape(points: points, closesPath: closesPath)
                .stroke(chalkColor.opacity(0.95), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct ChalkStrokeShape: Shape {
    let points: [CGPoint]
    let closesPath: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let firstPoint = points.first else { return path }

        path.move(to: firstPoint)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if closesPath, points.count >= 3 {
            path.closeSubpath()
        }
        return path
    }
}

private struct ScreenGridChalkDrawOverlayView: View {
    let drawInstruction: ScreenGridDrawInstruction
    let screenFrame: CGRect
    let onFinished: () -> Void

    @State private var drawProgress: CGFloat = 0
    @State private var overlayOpacity: Double = 1

    private let chalkColor = Color(red: 1.0, green: 0.92, blue: 0.35)

    private var outlineRect: CGRect? {
        ScreenGridAnnotationUtility.chalkOutlineRectInSwiftUICoordinates(
            gridCellLabels: drawInstruction.gridCellLabels,
            screenFrame: screenFrame
        )
    }

    private var cornerRadius: CGFloat {
        drawInstruction.gridCellLabels.count == 1 ? 14 : 18
    }

    var body: some View {
        ZStack {
            if let outlineRect {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(chalkColor.opacity(0.14))
                    .frame(width: outlineRect.width, height: outlineRect.height)
                    .position(x: outlineRect.midX, y: outlineRect.midY)

                ChalkRoundedRectOutlineShape(outlineRect: outlineRect, cornerRadius: cornerRadius)
                    .trim(from: 0, to: drawProgress)
                    .stroke(
                        chalkColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round)
                    )

                ChalkRoundedRectOutlineShape(outlineRect: outlineRect, cornerRadius: cornerRadius)
                    .trim(from: 0, to: drawProgress)
                    .stroke(
                        chalkColor.opacity(0.95),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .opacity(overlayOpacity)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.75)) {
                drawProgress = 1.0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                withAnimation(.easeOut(duration: 0.5)) {
                    overlayOpacity = 0.0
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
                onFinished()
            }
        }
    }
}

/// Rounded-rect path for chalk trim animation (absolute coordinates within the overlay).
private struct ChalkRoundedRectOutlineShape: Shape {
    let outlineRect: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: outlineRect, cornerRadius: cornerRadius, style: .continuous)
    }
}

/// Soft expanding chalk ring — brief celebrate when a goal checks out.
private struct CourseSuccessCelebrationOverlayView: View {
    let screenPoint: CGPoint
    let accentColor: Color
    let onFinished: () -> Void

    @State private var ringScale: CGFloat = 0.35
    @State private var ringOpacity: Double = 0.95
    @State private var fillOpacity: Double = 0.28

    private let chalkColor = Color(red: 1.0, green: 0.92, blue: 0.35)

    var body: some View {
        ZStack {
            Circle()
                .fill(chalkColor.opacity(fillOpacity))
                .frame(width: 88, height: 88)
                .scaleEffect(ringScale)

            Circle()
                .stroke(chalkColor.opacity(0.9), lineWidth: 3.5)
                .frame(width: 88, height: 88)
                .scaleEffect(ringScale)
                .shadow(color: chalkColor.opacity(0.55), radius: 10, x: 0, y: 0)

            Circle()
                .stroke(accentColor.opacity(0.55), lineWidth: 1.5)
                .frame(width: 62, height: 62)
                .scaleEffect(ringScale * 0.92)
        }
        .position(screenPoint)
        .opacity(ringOpacity)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                ringScale = 1.55
                fillOpacity = 0.06
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.easeOut(duration: 0.4)) {
                    ringOpacity = 0
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                onFinished()
            }
        }
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    let accentColor: Color
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        accentColor.opacity(0.0),
                        accentColor
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: accentColor.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
