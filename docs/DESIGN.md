# Teachy design language

**Teachy looks like part of macOS.** Someone who has never seen it should take it for something Apple shipped: SF Pro, system glass, grouped lists, system-style controls, springs. What makes it Teachy is restraint and three things of its own: the notch it lives in, the pointer, and the pointer's colour.

Tokens and components live in `leanring-buddy/DesignSystem.swift`. See them rendered: `scripts/tests/render_design_shots.sh`. Motion and material rules come from the `apple-design` skill.

## The rules

1. **System type.** SF Pro everywhere, at macOS sizes (`DS.Fonts`). Hierarchy comes from weight and from the label colours: `textPrimary` is the thing itself, `textSecondary` explains it, `textTertiary` is a detail. Sentence case. No serif, no rounded, no capitals with tracking. SF Mono (`DS.Fonts.mono`) only for real code, commands and file paths. Numbers that change use `DS.Fonts.data` (digits that do not jump).
2. **Glass for floating overlays; black for the expanded utility panel.**
   - **The closed notch is system glass** (`TeachyGlassSurface` in the notch's silhouette), as are the other floating overlays (job cards, the question card, captions, the reply bubble, pills): `.teachyTile()`. The expanded notch uses `DS.Colors.notchBlack`, following the compact utility reference. It is Liquid Glass on macOS 26, a material before that, and solid black with Reduce Transparency or Increase Contrast.
   - **Closed**, the notch is the *clear* glass variant, barely dimmed, so it reads as a transparent pane at rest and lightens a little under the pointer. **Open**, it becomes a quiet solid black panel. Floating tiles remain frosted.
   - Teachy's labels are white, so its glass carries a black dimming layer (`TeachyGlass.restingDimming`, `panelDimming`, `tileDimming`) to stay readable over a white document. Do not rely on a glass `tint` for this: it makes no visible difference.
   - Never glass on glass: groups and controls on glass use the translucent fills. No drawn shadows and no black hairlines on glass: they show through it as smudges.
3. **Grouped lists.** A heading (`TeachySectionTitle`), then the rows of that section in one rounded container (`.teachyGroup()` on a `VStack(spacing: 0)`), with dividers (`TeachyRule`) between rows. The container's fill is translucent, so the glass shows through it. This is how System Settings and iOS Settings look. Never one card per row, never a group inside a group. Inside a group the only other box is a field or a quoted command (`.teachyWell()`).
4. **System-style controls.** Capsule buttons (`.teachyButton`), the switch (`TeachySwitch`), SF Symbols for every icon and state. They are drawn in the design system instead of using AppKit's, because Teachy's panels never become the key window and system controls go grey there. Do not hand-roll a control in a view: if it is missing, add it to the design system.
5. **One tint.** `DS.Colors.pointer` is the pointer colour the person picked, and it is used exactly where macOS uses the accent colour: the main button, a switch that is on, the selected option, text buttons, row symbols, and whatever is live. Text on a tint fill is `DS.Colors.onPointer`. Beyond the tint: orange (`warning`) when Teachy needs you, red (`destructive`) when something failed or will be removed, green (`success`) for done. Nothing else has colour.
6. **The pointer is the mark.** `TeachyPointerShape` in the tint is Teachy's logo and its "working on it" indicator (`TeachyStatusMark(kind: .live)`).
7. **Motion is physical.** Feedback starts on mouse-down (scale 0.97, `DS.Motion.press`). Things open, close and move on `DS.Motion.standard`, a critically damped spring; a little bounce (`DS.Motion.thrown`) only after a flick or a drop. Things leave the way they came. Symbols change with `.contentTransition(.symbolEffect(.replace))`, numbers with `.contentTransition(.numericText())`. With Reduce Motion, cross-fade (`DS.Motion.reduced`). Nothing loops while idle.

## Never

- `Color(hex:)`, `Color.white.opacity(…)` or `.font(.system(size:…))` in a view. Use the tokens; add one if it is missing.
- A hand-drawn control, card, or tile background. Use the components.
- Glows, coloured shadows, gradients as decoration, blur as decoration.
- Avatar circles with an initial, icons in tinted squares, emoji, coloured pills and badges. (A capsule is right for a button, a switch and a real floating pill.)
- A second colour for decoration. Blue, purple or teal that is not the person's tint.
- Text under 11 pt. Paragraphs of grey small print: one line, or cut it.
- Lower-cased or upper-cased labels for effect.

## Components

| Need | Use |
| --- | --- |
| The one action | `.teachyButton(.primary)` (tint fill). One per surface. |
| Another action | `.teachyButton(.secondary)` (grey capsule) or `.quiet` (no fill) |
| Stop, delete | `.teachyButton(.danger)` |
| In a row or a tile | add `size: .compact` |
| One symbol | `.teachyIconButton()` |
| An action inside a row | `.teachyLinkButton()` (tint text); `color:` for red or grey |
| One of several | `.teachyOption(isSelected:)` (tint fill and edge when chosen) |
| On / off | `TeachySwitch` via `SettingsToggleRow` |
| A key | `KeyboardKeyLabel(text:)` |
| A state | `TeachyStatusMark(kind: .live / .done / .needsYou / .failed / .waiting / .stopped)` |
| A section heading | `TeachySectionTitle(title:detail:)` |
| A section's rows | `VStack(spacing: 0) { rows }.teachyGroup()` |
| A divider between rows | `TeachyRule()` |
| A settings row | `SettingsDisclosureCard` (a row that opens in place, inside a group) |
| Floats over the screen | `.teachyTile()`; `.teachyTile(cornerRadius: DS.CornerRadius.pill)` for a pill; `edgeColor: DS.Colors.warning` when it waits on you |
| Field, code, quote | `.teachyWell()` |
| A change of state worth feeling | `DS.Haptics.stateChanged()` on the same frame |

## Type

| Token | Size | For |
| --- | --- | --- |
| `display` | 22 bold | the one headline of a surface |
| `title` | 15 semibold | a section heading, a tile's heading |
| `itemTitle` | 13 semibold | a named thing in a list |
| `bodyEmphasized` | 13 medium | the label of a row |
| `body` / `voice` | 13 | running text; what Teachy says (line spacing 3) |
| `control` / `controlCompact` | 13 / 11.5 medium | buttons |
| `caption` | 11.5 | the line that explains a row, in `textSecondary` |
| `data` | 11, steady digits | times, counts, states, in `textSecondary` or `textTertiary` |
| `key` | 11 medium | key caps |

## Accessibility

Tiles go solid with Reduce Transparency and gain an edge with Increase Contrast (built into `.teachyTile()`). Swap springs for `DS.Motion.reduced` when `accessibilityReduceMotion` is on. Colour is never the only signal: every state has its own symbol.

## Checking your work

Render the view to a PNG (`scripts/tests/render_*_shots.sh`) and look at it. Off-screen renders cannot show real glass, so the notch and tiles appear as a dark frosted stand-in. To see real glass, run `scripts/tests/run_notch_demo.sh`: it shows the real notch view in a window on screen over a stand-in desktop, opens and closes it on a loop, and with `--record DIR` writes a video and a GIF of the window (only that window is captured). `--notched` adds a camera housing. Ask: would this pass for a screen Apple made, is every row in a group, is there a colour that is not the tint, orange, red or green, is anything hand-rolled that the design system already has.

## Notch navigation

Home is a compact utility dashboard: recent drawing previews, connection status, Open chat and the voice shortcut. Keep introductory paragraphs out of the everyday panel. Home and Agents share the header with Drawings and Settings icon buttons; longer pages scroll independently. Connections opens directly from Home. Account, always-on voice, preferences and memory live in Settings. Dragging a file returns to Home so progress remains visible.

The open shell is 520×240pt with a solid black surface, matching the requested compact utility reference. Passive chrome hugs the physical camera: 24pt wings and 8pt outside padding, without an extra one-sided gap. On screens without a notch, show only a 48pt indicator; never reserve an imaginary camera. Preserve clearance for active microphone bars as well.

Leaving the visible panel collapses it after 180ms; re-entering cancels collapse. File drags and native menu tracking temporarily keep it open. The transparent remainder of the hosting window must not extend the hover region. Verify with `scripts/tests/run_notch_hover_tests.sh`.

## Feature announcements

Use a centered 440pt native window with an intrinsic height (about 421pt for dictation), rounded glass surface, the Teachy pointer and a small feature symbol. One centered headline, a short explanation, relevant controls, and a single Got it button. The close button remains visible in the top right. Use 20pt `announcementTitle`, 13pt `announcementBody`, and the 34pt `.large` primary button. Three-key shortcuts move below the Shortcut label; the window grows for extra rows and validation messages. Keep actual preferences wired into announcement controls. Dismissal is remembered; Settings → Updates → What’s new reopens it.
