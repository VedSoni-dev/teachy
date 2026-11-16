//
//  DriveTakeoverMonitor.swift
//  leanring-buddy
//
//  While Teachy is driving an app, the user can take it back at any moment:
//  press Escape, click, or move the mouse more than ~40 points. A listen-only
//  CGEvent tap (same pattern as GlobalPushToTalkShortcutMonitor) watches for
//  that and stops the job at once. Also owns the small "Teachy is driving" pill.
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
}

private struct DrivePillView: View {
    @ObservedObject var model: DrivePillModel

    var body: some View {
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
                Text("takes it back")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .fixedSize()
        }
        .padding(.horizontal, DS.Spacing.lg)
        // 7 pt, not 8: the key cap is 20 pt tall and the pill's panel is 36 pt.
        .padding(.vertical, 7)
        .teachyTile(cornerRadius: DS.CornerRadius.pill)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
final class DriveTakeoverMonitor {
    static let shared = DriveTakeoverMonitor()

    /// How far the pointer may drift before it counts as the user taking over.
    static let mouseMovementThreshold: CGFloat = 40
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

    var isDriving: Bool { activeJobID != nil }

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

        switch type {
        case .keyDown:
            if keyCode == 53 { takeOver(jobID: jobID, how: "you pressed Escape") }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            takeOver(jobID: jobID, how: "you clicked")
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            guard Date() >= ignoreMovementUntil else { return }
            guard let anchor = mouseAnchor else { mouseAnchor = location; return }
            if hypot(location.x - anchor.x, location.y - anchor.y) > Self.mouseMovementThreshold {
                takeOver(jobID: jobID, how: "you moved the mouse")
            }
        default:
            break
        }
    }

    private func takeOver(jobID: String, how: String) {
        endDriving(jobID: jobID)
        AgentJobCenter.shared.job(withID: jobID)?.stop(reason: .userTookOver(how))
    }
}
