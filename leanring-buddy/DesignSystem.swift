//
//  DesignSystem.swift
//  leanring-buddy
//
//  Teachy looks like part of macOS.
//
//  - SF Pro, the system type, at the sizes macOS uses. Hierarchy comes from
//    weight and from the label colours (primary, secondary, tertiary).
//  - The notch is system glass, closed and open, and so is everything else that
//    floats over the screen (Liquid Glass on macOS 26, a material before it,
//    solid black with Reduce Transparency). Only the camera housing is black.
//  - Lists are grouped: a heading, then rows in one rounded container with
//    inset dividers, the way System Settings and iOS draw them.
//  - Controls look and behave like the system's: capsule buttons, a switch,
//    SF Symbols. They are drawn here rather than borrowed from AppKit because
//    Teachy's panels never become the key window, and system controls go grey
//    in a window that is not key.
//  - One brand colour: the pointer colour the person picked. It is the tint,
//    exactly where macOS would use the accent colour. Orange means Teachy needs
//    you, red means something failed or will be removed, green means done.
//  - Motion is springs; feedback starts on mouse-down.
//
//  The full write-up is docs/DESIGN.md.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.textPrimary`, `DS.Fonts.title`, `DS.Motion.standard`.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Surfaces ─────────────────────────────────────────────────
        // The Dark Mode system greys, written out so off-screen renders match.

        /// The camera housing, and what the notch becomes with Reduce
        /// Transparency. Pure black so it is one piece with the hardware.
        static let notchBlack = Color.black

        /// A window that is not part of the notch (the chat window). A step
        /// darker than a group, so a grouped container reads on it.
        static let background = Color(hex: "#141415")

        /// A grouped list's container (secondarySystemGroupedBackground).
        static let surface1 = Color(hex: "#1C1C1E")

        /// Something raised on a group (tertiarySystemGroupedBackground).
        static let surface2 = Color(hex: "#2C2C2E")

        /// The off track of a switch, a hovered raised surface.
        static let surface3 = Color(hex: "#3A3A3C")

        /// The face of a key cap, a pressed raised surface.
        static let surface4 = Color(hex: "#48484A")

        // ── Fills ────────────────────────────────────────────────────
        // Translucent, so the same control works on black, on a group and on glass.

        /// A pressed control.
        static let fillPrimary = Color.white.opacity(0.20)
        /// A resting control (a secondary button).
        static let fillSecondary = Color.white.opacity(0.12)
        /// A field, an unselected option.
        static let fillTertiary = Color.white.opacity(0.07)
        /// A hovered row.
        static let fillQuaternary = Color.white.opacity(0.045)
        /// A grouped list's container. Translucent so the glass of the notch
        /// panel shows through it, the way a group sits on a system glass sheet.
        static let groupFill = Color.white.opacity(0.075)

        // ── Lines ────────────────────────────────────────────────────

        /// The divider between rows of a group.
        static let hairline = Color.white.opacity(0.11)

        /// The edge of a field or a solid tile.
        static let hairlineStrong = Color.white.opacity(0.20)

        /// The edge of whichever option is selected: the tint.
        static var hairlineSelected: Color { pointer }

        // ── Labels ───────────────────────────────────────────────────
        // Translucent whites, like the system label colours: they stay legible
        // on black and pick up what is behind them on glass.

        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.66)
        static let textTertiary = Color.white.opacity(0.48)
        /// Placeholders, pending marks, disabled labels.
        static let textQuaternary = Color.white.opacity(0.28)

        // ── Tint (the pointer colour) ────────────────────────────────

        /// The pointer colour the person picked on the Home tab. It is Teachy's
        /// tint: the main button, a switch that is on, the chosen option, links,
        /// row symbols, and whatever is live. Read on every use so a new choice
        /// shows the next time a view is drawn.
        static var pointer: Color {
            pointerColor(named: UserDefaults.standard.string(forKey: "selectedCursorColor"))
        }

        /// Text or a symbol that sits on a pointer-colour fill.
        static var onPointer: Color {
            colorOnPointerColor(named: UserDefaults.standard.string(forKey: "selectedCursorColor"))
        }

        /// The four pointer colours. `ClickyCursorColor.displayColor` reads these,
        /// so the pointer on screen and the tint in the panel never drift apart.
        static func pointerColor(named pointerColorName: String?) -> Color {
            switch pointerColorName {
            case "red": return Color(hex: "#FF4D4D")
            case "yellow": return Color(hex: "#FFD60A")
            case "green": return Color(hex: "#30D158")
            default: return Color(hex: "#3380FF")
            }
        }

        /// White reads on blue and red; yellow and green are too light for it.
        static func colorOnPointerColor(named pointerColorName: String?) -> Color {
            switch pointerColorName {
            case "yellow", "green": return Color.black
            default: return Color.white
            }
        }

        // ── Meaning ──────────────────────────────────────────────────
        // The Dark Mode system colours.

        /// Teachy needs an answer or a look from you.
        static let warning = Color(hex: "#FF9F0A")
        static let warningText = Color(hex: "#FFB340")

        /// Something failed, or this action removes something.
        static let destructive = Color(hex: "#FF453A")
        static let destructiveText = Color(hex: "#FF6961")

        /// Done, granted, connected.
        static let success = Color(hex: "#30D158")

        // ── Disabled ─────────────────────────────────────────────────

        static var disabledBackground: Color { fillTertiary }
        static var disabledText: Color { textQuaternary }
    }

    // MARK: - Type

    /// SF Pro at macOS sizes. Nothing under 11 pt.
    enum Fonts {
        static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// SF Mono, only for real code, commands and file paths.
        static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// One per surface: the line the whole surface is about.
        static let display = sans(22, weight: .bold)
        /// The heading of a section or of a floating tile.
        static let title = sans(15, weight: .semibold)
        /// A named thing in a list (an agent, a job, a routine).
        static let itemTitle = sans(13, weight: .semibold)
        /// What Teachy says, at reading length. Give it line spacing 3.
        static let voice = sans(13)

        /// The label of a row.
        static let bodyEmphasized = sans(13, weight: .medium)
        static let body = sans(13)
        /// Buttons and small controls.
        static let control = sans(13, weight: .medium)
        static let controlCompact = sans(11.5, weight: .medium)
        /// The line that explains a row.
        static let caption = sans(11.5)

        /// Times, counts, statuses: SF Pro with digits that do not jump.
        static let data = sans(11).monospacedDigit()
        static let dataEmphasized = sans(11, weight: .medium).monospacedDigit()
        /// Key caps.
        static let key = sans(11, weight: .medium)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    /// Continuous corners throughout. Buttons are capsules, as on macOS 26.
    enum CornerRadius {
        /// Key caps and tags.
        static let key: CGFloat = 5
        static let small: CGFloat = 6
        /// Fields and options.
        static let control: CGFloat = 10
        static let medium: CGFloat = 10
        /// A recessed well.
        static let well: CGFloat = 10
        static let large: CGFloat = 12
        /// A grouped list's container.
        static let group: CGFloat = 14
        /// Glass tiles that float over the screen.
        static let tile: CGFloat = 20
        static let extraLarge: CGFloat = 20
        /// Pass to `teachyTile` for a glass capsule.
        static let pill: CGFloat = .infinity
    }

    // MARK: - Motion

    /// Springs, critically damped unless a gesture threw the thing.
    enum Motion {
        /// Press feedback. Starts on mouse-down.
        static let press = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 1.0)
        /// Everything that opens, closes, moves or swaps.
        static let standard = SwiftUI.Animation.spring(response: 0.34, dampingFraction: 1.0)
        /// Only after a flick or a drop: a little overshoot.
        static let thrown = SwiftUI.Animation.spring(response: 0.38, dampingFraction: 0.82)
        /// Hover colour changes.
        static let hover = SwiftUI.Animation.easeOut(duration: 0.12)
        /// What replaces a spring when Reduce Motion is on.
        static let reduced = SwiftUI.Animation.easeInOut(duration: 0.2)
    }

    /// Durations kept for older call sites.
    enum Animation {
        static let fast: Double = 0.12
        static let normal: Double = 0.25
        static let slow: Double = 0.4
    }

    // MARK: - Haptics

    /// A tap on the trackpad for the moments that are a real change of state:
    /// a switch flipping, a choice being made. Fires on the same frame as the
    /// change. Nothing happens on a mouse or a trackpad without Force Touch.
    enum Haptics {
        static func stateChanged() {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}

// MARK: - Buttons

/// How much a button asks for attention. One `.primary` per surface.
enum TeachyButtonKind {
    /// Filled with the pointer colour. The one thing to do here.
    case primary
    /// A grey capsule.
    case secondary
    /// No fill until hovered. For rows of small actions.
    case quiet
    /// Removes or stops something.
    case danger
}

enum TeachyButtonSize {
    /// 28 pt tall.
    case regular
    /// 22 pt tall, for rows and tiles.
    case compact
}

/// The Teachy button: a capsule, like the system's on macOS 26. Drawn here
/// because a system button goes grey in a panel that is not the key window.
/// Feedback starts on mouse-down; hover only changes tone.
struct TeachyButtonStyle: ButtonStyle {
    var kind: TeachyButtonKind = .secondary
    var size: TeachyButtonSize = .regular
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        TeachyButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            kind: kind,
            size: size,
            isFullWidth: isFullWidth
        )
    }
}

/// A view (not just a style) so it can read the environment and hold hover state.
private struct TeachyButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let kind: TeachyButtonKind
    let size: TeachyButtonSize
    let isFullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .font(labelFont)
            .foregroundColor(labelColor)
            .lineLimit(1)
            .padding(.horizontal, size == .regular ? 14 : 10)
            .frame(height: size == .regular ? 28 : 22)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .background(Capsule().fill(fillColor))
            .overlay {
                // The main button is lit from above, like a system prominent button.
                if kind == .primary {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.white.opacity(0.18), Color.clear], startPoint: .top, endPoint: .center))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .brightness(kind == .primary ? (isPressed ? -0.08 : (isHovered ? 0.05 : 0)) : 0)
            .scaleEffect(isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(DS.Motion.press, value: isPressed)
            .animation(DS.Motion.hover, value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .pointerCursor(isEnabled: isEnabled)
    }

    private var labelFont: Font {
        switch (size, kind) {
        case (.regular, .primary): return DS.Fonts.sans(13, weight: .semibold)
        case (.regular, _): return DS.Fonts.control
        case (.compact, .primary): return DS.Fonts.sans(11.5, weight: .semibold)
        case (.compact, _): return DS.Fonts.controlCompact
        }
    }

    private var labelColor: Color {
        switch kind {
        case .primary: return DS.Colors.onPointer
        case .secondary: return DS.Colors.textPrimary
        case .quiet: return isHovered || isPressed ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .danger: return DS.Colors.destructiveText
        }
    }

    private var fillColor: Color {
        switch kind {
        case .primary:
            return DS.Colors.pointer
        case .secondary:
            if isPressed { return DS.Colors.fillPrimary }
            return isHovered ? Color.white.opacity(0.16) : DS.Colors.fillSecondary
        case .quiet:
            if isPressed { return DS.Colors.fillSecondary }
            return isHovered ? DS.Colors.fillTertiary : Color.clear
        case .danger:
            if isPressed { return DS.Colors.destructive.opacity(0.34) }
            return DS.Colors.destructive.opacity(isHovered ? 0.26 : 0.18)
        }
    }
}

/// A round button that holds one symbol (close, previous, copy).
struct TeachyIconButtonStyle: ButtonStyle {
    var sideLength: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        TeachyIconButtonBody(label: configuration.label, isPressed: configuration.isPressed, sideLength: sideLength)
    }
}

private struct TeachyIconButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let sideLength: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .font(.system(size: sideLength * 0.44, weight: .semibold))
            .foregroundColor(isHovered || isPressed ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .frame(width: sideLength, height: sideLength)
            .background(
                Circle().fill(isPressed ? DS.Colors.fillPrimary : (isHovered ? DS.Colors.fillSecondary : Color.clear))
            )
            .contentShape(Circle())
            .scaleEffect(isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(DS.Motion.press, value: isPressed)
            .animation(DS.Motion.hover, value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .pointerCursor(isEnabled: isEnabled)
    }
}

/// A text button in the tint, the way macOS and iOS draw an action inside a
/// row (Rename, Open folder, Show all). Pass a colour for the exceptions
/// (red for Delete, secondary for something that should recede).
struct TeachyLinkButtonStyle: ButtonStyle {
    var color: Color? = nil
    var font: Font = DS.Fonts.caption

    func makeBody(configuration: Configuration) -> some View {
        TeachyLinkButtonBody(label: configuration.label, isPressed: configuration.isPressed, color: color, font: font)
    }
}

private struct TeachyLinkButtonBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let color: Color?
    let font: Font

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        label
            .font(font)
            .foregroundColor(color ?? DS.Colors.pointer)
            .brightness(isHovered ? 0.12 : 0)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (isPressed ? 0.55 : 1) : 0.4)
            .animation(DS.Motion.hover, value: isHovered)
            .onHover { hovering in isHovered = hovering }
            .pointerCursor(isEnabled: isEnabled)
    }
}

extension View {
    /// The Teachy button. `kind` is how loud it is, `size` is how tall.
    func teachyButton(_ kind: TeachyButtonKind = .secondary, size: TeachyButtonSize = .regular, isFullWidth: Bool = false) -> some View {
        buttonStyle(TeachyButtonStyle(kind: kind, size: size, isFullWidth: isFullWidth))
    }

    /// A round one-symbol button.
    func teachyIconButton(sideLength: CGFloat = 24) -> some View {
        buttonStyle(TeachyIconButtonStyle(sideLength: sideLength))
    }

    /// A text button in the tint. Pass `color` for red or a quieter grey.
    func teachyLinkButton(color: Color? = nil, font: Font = DS.Fonts.caption) -> some View {
        buttonStyle(TeachyLinkButtonStyle(color: color, font: font))
    }
}

// MARK: - Glass

private struct TeachyIsDrawnIntoPictureKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set to true on a view that is drawn into a picture inside the running app
    /// (`ImageRenderer` for video export, history thumbnails) instead of a window.
    /// Glass has nothing behind it to sample there, and AppKit-backed pieces
    /// cannot be drawn at all, so tiles go solid and the cursor overlay is left out.
    var teachyIsDrawnIntoPicture: Bool {
        get { self[TeachyIsDrawnIntoPictureKey.self] }
        set { self[TeachyIsDrawnIntoPictureKey.self] = newValue }
    }
}

enum TeachyGlass {
    /// Off-screen renders (the PNG harnesses in scripts/tests) have nothing
    /// behind them for glass to sample, so they draw a frosted stand-in.
    /// The harnesses run with the activation policy `.prohibited`; the app never does.
    static var usesStandIn: Bool {
        guard let application = NSApp else { return true }
        return application.activationPolicy() == .prohibited
    }

    /// How much the glass is dimmed. Teachy's labels are white, so its glass
    /// has to stay dark enough to read over a white document. A black layer of
    /// this opacity sits on the glass, under the content. (A black `tint` on the
    /// glass itself was tried and makes no visible difference.) The big panel
    /// holds small secondary text, so it is dimmed a little more than a tile.
    static let tileDimming: Double = 0.42
    static let panelDimming: Double = 0.5
    /// The closed notch holds nothing but the pointer and a few bars, which are
    /// bright and bold, so it is dimmed least: it reads as a clear pane at rest.
    static let restingDimming: Double = 0.12

    /// What the stand-in and the pre-macOS-26 material are filled with.
    static let standInFill = Color(white: 0.13).opacity(0.94)
}

/// System glass in any shape, as a background layer. The notch panel uses it
/// with the notch's own silhouette; tiles use `.teachyTile()`, which wraps the
/// same decisions for a rounded rectangle or a capsule.
struct TeachyGlassSurface<SurfaceShape: Shape>: View {
    let shape: SurfaceShape
    var dimming: Double = TeachyGlass.panelDimming
    /// `.clear` is the see-through glass, for a surface that holds little and
    /// should read as a pane. `.regular` frosts what is behind it.
    var isClear: Bool = false
    /// What the surface becomes when it cannot be glass (Reduce Transparency,
    /// Increase Contrast, a picture).
    var solidFill: Color = DS.Colors.notchBlack

    @Environment(\.accessibilityReduceTransparency) private var isReduceTransparencyEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.teachyIsDrawnIntoPicture) private var isDrawnIntoPicture

    var body: some View {
        if isReduceTransparencyEnabled || colorSchemeContrast == .increased || isDrawnIntoPicture {
            shape.fill(solidFill)
        } else if TeachyGlass.usesStandIn {
            shape.fill(TeachyGlass.standInFill)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(isClear ? .clear : .regular, in: shape)
                .overlay(shape.fill(Color.black.opacity(dimming)))
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(dimming)))
        }
    }
}

/// A surface that floats over the person's screen: job cards, the question
/// card, the caption bar, pills. System glass, always in its dark form so it
/// pairs with the black notch and white labels stay legible over any app.
struct TeachyTileModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.CornerRadius.tile
    /// An extra coloured edge, for a tile that is waiting on the person (orange).
    var edgeColor: Color = .clear

    @Environment(\.accessibilityReduceTransparency) private var isReduceTransparencyEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.teachyIsDrawnIntoPicture) private var isDrawnIntoPicture

    private var tileShape: AnyShape {
        cornerRadius.isInfinite
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var tileInsettableShape: some InsettableShape {
        RoundedRectangle(cornerRadius: cornerRadius.isInfinite ? 999 : cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        surfaced(content)
            .overlay(tileInsettableShape.strokeBorder(edgeColor, lineWidth: 1.5).allowsHitTesting(false))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if isReduceTransparencyEnabled || colorSchemeContrast == .increased || isDrawnIntoPicture {
            content
                .background(tileShape.fill(DS.Colors.surface1))
                .overlay(tileInsettableShape.strokeBorder(DS.Colors.hairlineStrong, lineWidth: 1).allowsHitTesting(false))
        } else if TeachyGlass.usesStandIn {
            content
                .background(tileShape.fill(TeachyGlass.standInFill))
                .overlay(
                    tileInsettableShape
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                )
        } else if #available(macOS 26.0, *) {
            // The dimming layer keeps white labels readable when the tile sits over a white document.
            content
                .background(tileShape.fill(Color.black.opacity(TeachyGlass.tileDimming)))
                .glassEffect(.regular, in: tileShape)
        } else {
            content
                .background(tileShape.fill(Color.black.opacity(TeachyGlass.tileDimming)))
                .background(tileShape.fill(.ultraThinMaterial))
                .overlay(
                    tileInsettableShape
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75
                        )
                        .allowsHitTesting(false)
                )
        }
    }
}

/// A recessed area inside a surface: a text field, a quoted command.
struct TeachyWellModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.CornerRadius.well
    var isEdged: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DS.Colors.fillTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isEdged ? DS.Colors.hairline : Color.clear, lineWidth: 1)
            )
    }
}

/// The container of a grouped list, as in System Settings: the rows of one
/// section in one rounded rectangle, with dividers between them.
/// Put the rows in a `VStack(spacing: 0)` and apply this to the stack.
struct TeachyGroupModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.CornerRadius.group
    var horizontalPadding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            // Rows that end with their own divider (SettingsDisclosureCard) would
            // leave a line along the bottom edge. Pulling the bottom in by one
            // point puts that last divider outside the clip.
            .padding(.bottom, -1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.groupFill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// One choice among several (a voice, a microphone). The chosen one takes the
/// tint: a tinted fill and a tinted edge.
struct TeachyOptionModifier: ViewModifier {
    var isSelected: Bool
    var cornerRadius: CGFloat = DS.CornerRadius.control

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? DS.Colors.pointer.opacity(0.18) : (isHovered ? DS.Colors.fillSecondary : DS.Colors.fillTertiary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.pointer : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .animation(DS.Motion.hover, value: isHovered)
            .animation(DS.Motion.standard, value: isSelected)
            .onHover { hovering in isHovered = hovering }
    }
}

extension View {
    /// System glass for something that floats over the screen. See `TeachyTileModifier`.
    func teachyTile(cornerRadius: CGFloat = DS.CornerRadius.tile, edgeColor: Color = .clear) -> some View {
        modifier(TeachyTileModifier(cornerRadius: cornerRadius, edgeColor: edgeColor))
    }

    /// A recessed well. See `TeachyWellModifier`.
    func teachyWell(cornerRadius: CGFloat = DS.CornerRadius.well, isEdged: Bool = false) -> some View {
        modifier(TeachyWellModifier(cornerRadius: cornerRadius, isEdged: isEdged))
    }

    /// The rounded container of a grouped list. See `TeachyGroupModifier`.
    func teachyGroup(cornerRadius: CGFloat = DS.CornerRadius.group, horizontalPadding: CGFloat = 14) -> some View {
        modifier(TeachyGroupModifier(cornerRadius: cornerRadius, horizontalPadding: horizontalPadding))
    }

    /// One choice among several. See `TeachyOptionModifier`.
    func teachyOption(isSelected: Bool, cornerRadius: CGFloat = DS.CornerRadius.control) -> some View {
        modifier(TeachyOptionModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        modifier(PointerCursorModifier(isEnabled: isEnabled))
    }
}

private struct PointerCursorModifier: ViewModifier {
    let isEnabled: Bool
    @Environment(\.teachyIsDrawnIntoPicture) private var isDrawnIntoPicture

    func body(content: Content) -> some View {
        content.overlay {
            // The cursor view is AppKit; a picture renderer cannot draw it.
            if isEnabled && !isDrawnIntoPicture {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Dividers and headings

/// The divider between rows of a group.
struct TeachyRule: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.hairline)
            .frame(height: 1)
    }
}

/// The heading above a group ("Settings", "Routines"), with an optional count
/// or state beside it ("3", "1 running").
struct TeachySectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(DS.Fonts.sans(12).monospacedDigit())
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The pointer mark

/// Teachy's pointer, drawn small: the same tilted triangle that moves on screen.
/// It is the brand mark, and in a list it marks what is live.
struct TeachyPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sideLength = min(rect.width, rect.height)
        let triangleHeight = sideLength * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - triangleHeight / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - sideLength / 2, y: rect.midY + triangleHeight / 3))
        path.addLine(to: CGPoint(x: rect.midX + sideLength / 2, y: rect.midY + triangleHeight / 3))
        path.closeSubpath()
        return path.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: -35 * .pi / 180)
                .translatedBy(x: -rect.midX, y: -rect.midY)
        )
    }
}

// MARK: - Status mark

/// What state a job, a routine or a step is in. An SF Symbol each, so the
/// shape carries the meaning and colour is never the only signal.
enum TeachyStatusKind {
    /// Teachy is working on it right now: the pointer, in the person's colour.
    case live
    /// Finished: a green tick.
    case done
    /// Waiting on the person: an orange exclamation mark.
    case needsYou
    /// Failed: a red cross.
    case failed
    /// Not started yet: an empty circle.
    case waiting
    /// Stopped or paused: a grey minus.
    case stopped
}

struct TeachyStatusMark: View {
    let kind: TeachyStatusKind
    var sideLength: CGFloat = 14

    var body: some View {
        Group {
            switch kind {
            case .live:
                TeachyPointerShape()
                    .fill(DS.Colors.pointer)
                    .padding(sideLength * 0.1)
            case .done:
                symbol("checkmark.circle.fill", color: DS.Colors.success)
            case .needsYou:
                symbol("exclamationmark.circle.fill", color: DS.Colors.warning)
            case .failed:
                symbol("xmark.circle.fill", color: DS.Colors.destructive)
            case .waiting:
                Image(systemName: "circle")
                    .font(.system(size: sideLength * 0.93, weight: .medium))
                    .foregroundStyle(DS.Colors.textQuaternary)
            case .stopped:
                symbol("minus.circle.fill", color: DS.Colors.surface4)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .accessibilityHidden(true)
    }

    /// A filled circle in the state's colour with its glyph knocked out in white,
    /// the way macOS draws them in notifications and Settings.
    private func symbol(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: sideLength * 0.93, weight: .medium))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.white, color)
    }
}

// MARK: - Switch

/// The system switch, drawn here so it keeps its colour in a panel that is not
/// the key window. On is the tint.
struct TeachySwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? DS.Colors.pointer : DS.Colors.surface3)
            .frame(width: 36, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(0.28), radius: 1.5, y: 1)
                    .padding(2)
            }
            .animation(DS.Motion.standard, value: isOn)
    }
}

// MARK: - Slider

/// The system slider, drawn here so it keeps its tint in a panel that is not
/// the key window. The knob follows the pointer one to one, and a click on the
/// track moves the knob there, as the system's does.
struct TeachySlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    /// Same shape as the system `Slider(value:in:)`, so one swaps for the other.
    init(value: Binding<Double>, in range: ClosedRange<Double>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    private let trackHeight: CGFloat = 4
    private let knobDiameter: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let travelWidth = max(1, geometry.size.width - knobDiameter)
            let rangeLength = range.upperBound - range.lowerBound
            let filledFraction = rangeLength > 0 ? CGFloat((value - range.lowerBound) / rangeLength) : 0
            let knobLeadingOffset = travelWidth * min(max(filledFraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.fillSecondary)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(DS.Colors.pointer)
                    .frame(width: knobLeadingOffset + knobDiameter / 2, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .shadow(color: Color.black.opacity(0.3), radius: 1.5, y: 1)
                    .scaleEffect(isDragging ? 1.1 : 1)
                    .offset(x: knobLeadingOffset)
                    .animation(DS.Motion.press, value: isDragging)
            }
            .frame(height: knobDiameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragValue in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let pointerFraction = min(max((dragValue.location.x - knobDiameter / 2) / travelWidth, 0), 1)
                        value = range.lowerBound + Double(pointerFraction) * rangeLength
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: knobDiameter)
        .pointerCursor()
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Key cap

/// A key on the keyboard, drawn as a key: a lit top face over a darker front edge.
struct KeyboardKeyLabel: View {
    let text: String
    /// Larger, for the one place a shortcut is the headline.
    var isProminent: Bool = false

    private var keyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isProminent ? 7 : DS.CornerRadius.key, style: .continuous)
    }

    var body: some View {
        Text(text)
            .font(isProminent ? DS.Fonts.sans(13, weight: .medium) : DS.Fonts.key)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, isProminent ? 9 : 6)
            .padding(.top, isProminent ? 4 : 2)
            .padding(.bottom, isProminent ? 5 : 3)
            .background(keyShape.fill(DS.Colors.surface4))
            .overlay(
                // Light catches the top edge of the key.
                keyShape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            // The front edge of the key, showing below the face.
            .padding(.bottom, 1.5)
            .background(keyShape.fill(DS.Colors.surface2))
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
///
/// Pass-through hit testing (like `PointerCursorNSView`/`IBeamCursorNSView` above) is
/// required here: `NSView.toolTip` is driven by AppKit's tracking-area system, not
/// hit testing, so the overlay never needs to intercept clicks — but a plain `NSView`
/// intercepts them by default, which silently ate taps on anything this modifier was
/// attached to until this was added.
private class NativeTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NativeTooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
