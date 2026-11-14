# TeachyScene: the scene script

Teachy's drawing engine does not ask the model for code or JSON. The model streams a short script, one command per line, and the engine draws each line the moment it arrives. High-level commands (`gear`, `dna`, `fan`, `piston`) expand into geometry inside the engine, so a labelled turbofan costs about 350 output tokens.

- Compact prompt the model sees: `leanring-buddy/Scene/SceneScriptPrompt.swift`
- Parser: `SceneScriptParser.swift`. Part library: `SceneParts.swift`. Maths: `SceneGeometry.swift`
- Try it without a model: `TEACHY_SCENE_DEMO=turbofan Teachy.app/Contents/MacOS/Teachy` (samples: turbofan, dna, gears, pendulum, card, overlay, piston, solar, bounce, board, spring). `TEACHY_SCENE_DEMO_SCRIPT=/path/file` shows any script file.

## Line format

```
verb id key=value key="quoted text" flag
```

- `id` is a short word. It is optional; the engine makes one up if it is missing.
- Values have no spaces unless quoted. `at=1, 2, 3` and `at=(1,2,3)` are repaired.
- Numbers may carry units (`30deg`, `1.5m`); the unit is ignored.
- Point lists: `pts=x,y;x,y;x,y` (2D) or `pts=x,y,z;x,y,z` (3D). `[[1,2],[3,4]]` also works.
- Colours by name (red orange amber yellow gold green lime teal cyan blue sky navy indigo purple violet pink magenta white black gray silver steel metal brown copper bronze cream tan glass ink pcb), `dark…`/`light…` variants, or `#rrggbb`.
- Blank lines, `# comments`, `// comments`, code fences, list bullets and prose are skipped. An unknown verb or a line missing a required argument is skipped. Nothing is fatal.
- Unknown keys are ignored. Common synonyms are accepted (`position`, `radius`, `colour`, `points`, `height`…).

## Timing

```
say 1 "A turbofan is a big fan wrapped around a small jet engine."
```

`say N "sentence"` gives the sentence to speak and ties the lines after it to sentence N. `@N` does the same without text (alone on a line, or as a prefix: `@3 ring …`). With speech, a line is drawn when the host calls `sentenceStarted(index: N)`. Without speech, lines are drawn in order about 0.09 s apart with a half-second pause between sentences. A sentence that never starts is released after 8 s.

## Surfaces

A script normally uses one of three surfaces. Shared verbs are routed by their arguments: `label` with `on=` is a 3D chip and with `at=x,y` a 2D pill; `chip "text"` is a follow-up question and `chip id at=… size=…` a component; `arrow` with three-number points is 3D.

### Overlay (on the live screen)

Coordinates are 0–1000 across and down the screenshot the model was shown. The host maps them onto the right display. Everything is drawn hand-style: wobble comes from a random generator seeded by the item's id, so the same script always draws the same strokes.

| Verb | Arguments |
|---|---|
| `ring` (`ellipse`, `circle`) | `at=x,y r=` or `rx= ry=` |
| `rect` | `from=x,y to=x,y` (or `at=` centre with `size=w,h`) |
| `arrow` | `from=x,y to=x,y`, `bend=0.3` for a curve |
| `line` (`polyline`) | `pts=…`, `smooth`, `closed` |
| `poly` (`polygon`) | `pts=…` |
| `label` (`pill`) | `at=x,y text="…"` |
| `highlight` | `from=x,y to=x,y`; fades after 2 s (`for=` seconds to change) |

Options on any of them: `color=`, `w=` stroke width, `dash`, `fill` (hatching), `label="…"` (a pill beside the shape), `for=seconds`. Shapes stay while Teachy speaks and fade when the host calls `speechEnded()`.

### Card (a floating sheet of grid paper)

```
card c title="The chain rule"
text "…"            bullet "…"            formula "dy/dx = dy/du × du/dx"
steps "x" "u = 3x² + 1" "y = ln u"        (or steps items="A > B > C")
chart ch type=bar|line|point data=1,4,9 labels="a|b|c" title="…" x="…" y="…"
image query="GE9X turbofan" caption="…"   (the host's imageFetcher finds the photo)
chip "A follow-up question"
```

Lines go to the most recent `card`. A second `card` with a new id opens a second window.

### 3D model (a transparent window you can turn)

`scene3d id title="…"` opens it. Y is up. Units are whatever the script likes: the camera fits the model. The model sways gently until the person drags it. Clicking a part calls `onPartTapped(id, label)`.

Shapes:

| Verb | Arguments |
|---|---|
| `box` | `size=w,h,d`, `round=` |
| `sphere` | `r=` |
| `cyl`, `capsule` | `r= h= axis=x|y|z`, or `from=x,y,z to=x,y,z` |
| `cone` | `r=` (base) `r2=` (top) `h= axis=` |
| `torus` | `r=` ring, `r2=` pipe, `axis=` |
| `tube` (`pipe`) | `pts=x,y,z;… r=`, `smooth`, `closed` |
| `lathe` | `pts=r,y;r,y;…` profile spun round `axis=`; `sweep=250` leaves a cutaway that opens toward the viewer, and a closed profile gets flat cut faces |
| `extrude` | `pts=x,y;…` outline, `depth=`, `hole=` |
| `arrow3` | `from= to= r=` |
| `text3` | `at= text="…" size=` (always faces the viewer) |
| `group` | an empty parent for `parent=` |

Any part: `at=x,y,z` `rot=x,y,z` (degrees) `axis=` `scale=` `color=` `opacity=` `mat=plastic|metal|glass|glow|matte|rubber` `glow` `parent=id` `rpm=` `label="Name"` `n=1` `name="…"`. `label=` shows a chip with a leader line; `n=` puts a numbered dot on it; `name=` only names the part for clicks. `label id on=partId text="…" n= side=up|down|left|right` adds a chip afterwards (pieces of a ready-made part can be addressed, e.g. `on=d.strand1`).

Ready-made parts:

| Verb | What you get |
|---|---|
| `gear id teeth= r= thick= hole=` | a spur gear (axis z by default) |
| `gear id teeth= mesh=other angle=deg` | same tooth size as `other`, placed touching it at `angle`, teeth interlocked, and coupled so it turns at the right ratio |
| `fan id blades= r= hub= pitch= axis= rpm=` (`blades`, `rotor`) | hub and pitched blades |
| `dna id turns= r= h= pairs=` | two backbones and coloured base pairs |
| `helix id turns= r= h= strands=` | one or more coils |
| `spring id from= to= coils= r=` | a coil; with `a=partId b=partId` it follows two parts, and with `k=` (and `rest=`, `damp=`) it pulls on them |
| `piston id bore= stroke= rod= rpm=` | cylinder (cut away), piston, rod and crank, all moving. Pieces: `id.cylinder id.head id.rod id.crank id.pin` |
| `wheel id r= w= spokes=` | tyre, rim, hub, spokes |
| `flow id pts=… color= speed= n=` | arrowheads travelling along a path |
| `board id size=w,d` then `comp id on=board at=x,z size=w,d[,h] label="…"` | a flat board with blocks sitting on it |
| `axes id size=` | X, Y, Z arrows |

Motion (the id is the part that moves):

```
spin partId rpm= axis=            move partId to=x,y,z dur=2 loop     (or by=)
pulse partId                      explode [groupId] axis=x dist=1     (dist=0 puts it back)
orbit partId around=otherId r= period= tilt=
camera to=x,y,z look=x,y,z dur=   hide id / show id / remove id / clear
```

Scripted speeds above 240 rpm (150 for pistons) are capped so the motion can be seen.

### Simulation

This is the part the competitor does not have: the person changes a number and the model responds.

```
gravity g=9.8                     ground y=0 size=10
fixed id at=x,y,z                 body id shape=sphere|box|cyl|capsule r= size= mass= at= vel=x,y,z bounce= friction=
joint ball|hinge|slider id a=fixedId b=bodyId at= axis= length=
spring id a=id b=id k= rest=      force id f=x,y,z      impulse id v=x,y,z
mesh gearA gearB ratio=3
slider id min= max= value= label="…" bind=target
plot id of=partId.property label="…"
set sliderId value=               (what a dragged slider is recorded as)
```

Slider targets: `gravity`, `speed` (time scale), `jointId.length`, `bodyId.mass`, `bodyId.bounce`, `partId.rpm`, `orbitId.period`, `orbitId.r`, `springId.k`, `springId.rest`, `partId.x|y|z`, `partId.scale`, `partId.opacity`. With no property the obvious one is used (a joint's length, a body's mass, otherwise rpm).

Plot properties: `x`, `y`, `z`, `speed`, `angle` (of a body hanging from a joint, in degrees), `rpm`.

How each thing is simulated:

| Thing | Method |
|---|---|
| Falling, bouncing, colliding bodies; pendulums and other jointed bodies | SceneKit physics |
| Gears | Kinematic: rpm spreads through the train (driven = −driver ÷ ratio) |
| Orbits, pistons, flow | Kinematic, advanced every frame |
| A body on a `spring … k=` | The engine's own integrator (semi-implicit Euler, 8 steps a frame). SceneKit's solver gained energy with stiff springs |

## Hosting

```swift
let scene = SceneSession()
scene.onPartTapped = { id, label in ask("Tell me about the \(label)") }
scene.onChipTapped = { question in ask(question) }
scene.imageFetcher = { query in await photo(for: query) }
scene.begin(anchor: .display(frame: screenshotDisplayFrame, timing: .speech))
let stream = try await TeachyAIRouter.openStream(job: .scene, hasImages: false, session: session,
                                                 body: SceneScriptPrompt.requestBody(question: question))
for try await delta in contentDeltas(of: stream) { scene.feed(chunk: delta) }
scene.end()
// from the speech engine
scene.sentenceStarted(index: n)
scene.speechEnded()
```

- `scene.onSay = { index, text in … }` hands over each `say` sentence if the host wants the narration from the same stream.
- Hosts with their own overlay set `anchor.hostsOverlay = true` and draw `SceneOverlayView(model: scene.overlayModel, mapping: rect)`.
- `scene.replay()` plays the drawing again with its original timing. `scene.log.encoded()` saves it; `scene.replay(saved, anchor:)` loads it. Slider drags are in the log.
- `scene.exportMP4(to:)` is a stub that throws; see the note on the method.

## Tests and eval

- `scripts/tests/run_scene_tests.sh`: parser, fuzzing, geometry, part library, scheduler, replay log.
- `scripts/eval/run_scene_eval.sh`: ten prompts through `TeachyAIRouter`, one call each, with a results table. Answers are saved so they can be opened with `TEACHY_SCENE_DEMO_SCRIPT`.
