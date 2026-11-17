//
//  DriveTakeoverMonitor.swift
//  leanring-buddy
//
//  While Teachy is driving an app, the person can borrow the mouse at any
//  moment: a click, or moving the mouse more than ~40 points, hands control
//  back to them without ending the job. Teachy's next mouse or keyboard
//  action waits until they have held still for 3 seconds (the pill counts
//  down: "Stay still and I'll take control again in 3"). Escape ends computer
//  use for the job. A listen-only CGEvent tap (same pattern as
//  GlobalPushToTalkShortcutMonitor) watches for all of it. Also owns the
//  small "Teachy is driving" pill.
//
//  If the tap cannot be installed, Drive refuses to start: no way to take
//  control back means no driving.
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// Where the agent's little panels hang: top centre of the screen the pointer is on, under the notch.
@MainActor
enum AgentNotchLayout {
    static let gapUnderNotch: CGFloat = 6
    static let pillSlotHeight: CGFloat = 40

    static func screenUnderPointer() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
    }

    /// Frame for a panel of `size`, pushed down by `offset` points (to sit under the pill).
    static func frame(for size: NSSize, offset: CGFloat = 0, on screen: NSScreen? = nil) -> NSRect? {
        guard let screen = screen ?? screenUnderPointer() else { return nil }
        let topInset = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - topInset - gapUnderNotch - offset - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func makePanel(size: NSSize, acceptsClicks: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = !acceptsClicks
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

@MainActor
final class DrivePillModel: ObservableObject {
    @Published var note = ""
    /// Set while the person has the mouse: whole seconds left before Teachy takes it back.
    @Published var secondsUntilTeachyTakesControl: Int?
}

private struct DrivePillView: View {
    @ObservedObject var model: DrivePillModel

    var body: some View {
        Group {
            if let secondsLeft = model.secondsUntilTeachyTakesControl {
                personHasControlContent(secondsLeft: secondsLeft)
            } else {
                teachyIsDrivingContent
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        // 7 pt, not 8: the key cap is 20 pt tall and the pill's panel is 36 pt.
        .padding(.vertical, 7)
        .teachyTile(cornerRadius: DS.CornerRadius.pill)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func personHasControlContent(secondsLeft: Int) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            TeachyStatusMark(kind: .needsYou)
            Text("Stay still and I'll take control again in \(secondsLeft)")
                .font(DS.Fonts.controlCompact.monospacedDigit())
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize()
            HStack(spacing: DS.Spacing.xs) {
                KeyboardKeyLabel(text: "esc")
                Text("leaves computer use")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .fixedSize()
        }
    }

    private var teachyIsDrivingContent: some View {
        HStack(spacing: DS.Spacing.sm) {
            TeachyStatusMark(kind: .live)
            Text("Teachy is driving")
                .font(DS.Fonts.controlCompact)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize()
            if !model.note.isEmpty {
                Text("· \(model.note)")
                    .font(DS.Fonts.data)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: DS.Spacing.xs) {
                KeyboardKeyLabel(text: "esc")
                Text("stops")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .fixedSize()
        }
    }
}

@MainActor
final class DriveTakeoverMonitor {
    static let shared = DriveTakeoverMonitor()

    /// How far the pointer may drift before it counts as the user taking over.
    static let mouseMovementThreshold: CGFloat = 40
    /// How long the person must hold still before Teachy takes the mouse back.
    static let stillnessSecondsBeforeTeachyTakesControl: TimeInterval = 3
    /// While the person has the mouse, movement smaller than this (a hand resting
    /// on a trackpad) does not restart the countdown.
    static let stillnessJitterThreshold: CGFloat = 3
    private static let pillSize = NSSize(width: 600, height: 36)

    private(set) var activeJobID: String?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseAnchor: CGPoint?
    private var suspendDepth = 0
    /// Mouse movement is ignored until this moment: the hand that just clicked "Go ahead"
    /// is still moving away from the button. Escape and clicks count at once.
    private var ignoreMovementUntil = Date.distantPast
    private static let movementGraceSeconds: TimeInterval = 1.5
    private let pillModel = DrivePillModel()
    private var pillPanel: NSPanel?

    /// Non-nil while the person has borrowed the mouse: the last moment they moved,
    /// clicked or typed. Teachy takes control back once this is 3 seconds old.
    private var personLastActiveWhileHoldingControlAt: Date?
    private var lastPointerLocationWhileHoldingControl: CGPoint?
    private var countdownTimer: Timer?

    var isDriving: Bool { activeJobID != nil }

    /// True while the person has the mouse and Teachy is waiting for them to hold still.
    func personHasControl(jobID: String) -> Bool {
        activeJobID == jobID && personLastActiveWhileHoldingControlAt != nil
    }

    /// Waits, without a time limit, until Teachy has the mouse back (the person held
    /// still for 3 seconds) or driving ended. True when it had to wait at all.
    func waitUntilTeachyHasControl(jobID: String) async -> Bool {
        var hadToWait = false
        while personHasControl(jobID: jobID) && !Task.isCancelled {
            hadToWait = true
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return hadToWait
    }

    /// Starts the watch and shows the pill. False when the watch could not be installed.
    func beginDriving(jobID: String, appName: String) -> Bool {
        if activeJobID == jobID { return true }
        if let other = activeJobID, other != jobID {
            // One drive session at a time.
            return false
        }
        guard installTap() else { return false }
        activeJobID = jobID
        mouseAnchor = nil
        suspendDepth = 0
        ignoreMovementUntil = Date().addingTimeInterval(Self.movementGraceSeconds)
        pillModel.note = "working in \(appName)"
        showPill()
        AgentJobCenter.shared.job(withID: jobID)?.isDriving = true
        return true
    }

    func setNote(_ note: String, jobID: String) {
        guard activeJobID == jobID else { return }
        pillModel.note = note
    }

    func endDriving(jobID: String) {
        guard activeJobID == jobID else { return }
        activeJobID = nil
        if personLastActiveWhileHoldingControlAt != nil {
            AgentJobCenter.shared.job(withID: jobID)?.budget.resume(now: Date())
        }
        stopHoldingControlCountdown()
        removeTap()
        pillPanel?.orderOut(nil)
        AgentJobCenter.shared.job(withID: jobID)?.isDriving = false
    }

    /// Teachy just moved the real pointer itself (the computer tool): measure the
    /// person's movement from here, not from where the pointer used to be.
    func noteOwnPointerMovement(jobID: String) {
        guard activeJobID == jobID else { return }
        mouseAnchor = nil
        ignoreMovementUntil = Date().addingTimeInterval(0.3)
    }

    /// While a consent card is up the user has to move and click; that is not a takeover.
    func suspend() {
        suspendDepth += 1
    }

    func resume() {
        suspendDepth = max(0, suspendDepth - 1)
        mouseAnchor = nil
        ignoreMovementUntil = Date().addingTimeInterval(Self.movementGraceSeconds)
    }

    // MARK: Pill

    private func showPill() {
        let panel = pillPanel ?? {
            let created = AgentNotchLayout.makePanel(size: Self.pillSize, acceptsClicks: false)
            created.contentView = NSHostingView(rootView: DrivePillView(model: pillModel))
            return created
        }()
        pillPanel = panel
        if let frame = AgentNotchLayout.frame(for: Self.pillSize) {
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        if eventTap != nil { return true }
        let eventTypes: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DriveTakeoverMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's source is on the main run loop, so this is the main thread.
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let marker = event.getIntegerValueField(.eventSourceUserData)
            let location = event.location
            MainActor.assumeIsolated {
                monitor.handle(type: type, keyCode: keyCode, marker: marker, location: location)
            }
            return Unmanaged.passUnretained(event)
        }

        var created: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            created = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if created != nil { break }
        }
        guard let tap = created, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            if let created { CFMachPortInvalidate(created) }
            print("⚠️ Drive: could not create the takeover event tap (Accessibility permission?)")
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(type: CGEventType, keyCode: Int64, marker: Int64, location: CGPoint) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let jobID = activeJobID, suspendDepth == 0 else { return }
        // Keys and clicks Drive posted itself are not the user.
        if marker == DriveSession.syntheticEventMarker { return }

        // Escape always ends computer use, whoever has the mouse.
        if type == .keyDown && keyCode == 53 {
            takeOver(jobID: jobID, how: "you pressed Escape")
            return
        }

        if personLastActiveWhileHoldingControlAt != nil {
            noteActivityWhileHoldingControl(type: type, location: location)
            return
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            startHoldingControl(location: location)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard Date() >= ignoreMovementUntil else { return }
            guard let anchor = mouseAnchor else { mouseAnchor = location; return }
            if hypot(location.x - anchor.x, location.y - anchor.y) > Self.mouseMovementThreshold {
                startHoldingControl(location: location)
            }
        default:
            break
        }
    }

    // MARK: The person borrowing the mouse

    /// The person grabbed the mouse: Teachy stops acting (its next action waits)
    /// and counts down 3 still seconds before taking it back.
    private func startHoldingControl(location: CGPoint) {
        personLastActiveWhileHoldingControlAt = Date()
        lastPointerLocationWhileHoldingControl = location
        if let activeJobID { AgentJobCenter.shared.job(withID: activeJobID)?.budget.pause(now: Date()) }
        refreshHoldingControlCountdown()
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { DriveTakeoverMonitor.shared.refreshHoldingControlCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// Any click, key or real pointer movement restarts the 3-second countdown.
    private func noteActivityWhileHoldingControl(type: CGEventType, location: CGPoint) {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged:
            personLastActiveWhileHoldingControlAt = Date()
            lastPointerLocationWhileHoldingControl = location
        case .mouseMoved:
            let previousLocation = lastPointerLocationWhileHoldingControl ?? location
            if hypot(location.x - previousLocation.x, location.y - previousLocation.y) > Self.stillnessJitterThreshold {
                personLastActiveWhileHoldingControlAt = Date()
                lastPointerLocationWhileHoldingControl = location
            }
        default:
            break
        }
        refreshHoldingControlCountdown()
    }

    private func refreshHoldingControlCountdown() {
        guard let lastActiveAt = personLastActiveWhileHoldingControlAt else { return }
        let secondsLeft = Self.stillnessSecondsBeforeTeachyTakesControl - Date().timeIntervalSince(lastActiveAt)
        if secondsLeft <= 0 {
            teachyTakesControlBack()
            return
        }
        let wholeSecondsLeft = Int(secondsLeft.rounded(.up))
        if pillModel.secondsUntilTeachyTakesControl != wholeSecondsLeft {
            pillModel.secondsUntilTeachyTakesControl = wholeSecondsLeft
        }
    }

    private func teachyTakesControlBack() {
        if let activeJobID { AgentJobCenter.shared.job(withID: activeJobID)?.budget.resume(now: Date()) }
        stopHoldingControlCountdown()
        // Measure the next takeover from where the person left the pointer.
        mouseAnchor = nil
        ignoreMovementUntil = Date().addingTimeInterval(0.3)
    }

    private func stopHoldingControlCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        personLastActiveWhileHoldingControlAt = nil
        lastPointerLocationWhileHoldingControl = nil
        pillModel.secondsUntilTeachyTakesControl = nil
    }

    private func takeOver(jobID: String, how: String) {
        endDriving(jobID: jobID)
        AgentJobCenter.shared.job(withID: jobID)?.stop(reason: .userTookOver(how))
    }
}
