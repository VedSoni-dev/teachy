# TeachyScene: the scene script

Teachy's drawing engine does not ask the model for code or JSON. The model streams a short script, one command per line, and the engine draws each line the moment it arrives. High-level commands (`gear`, `dna`, `fan`, `piston`) expand into geometry inside the engine, so a labelled turbofan costs about 350 output tokens.

- Compact prompts the model sees: `leanring-buddy/Scene/SceneScriptPrompt.swift` (`system` for explaining a thing, `annotateSystem` for marking up the screen)
- Parser: `SceneScriptParser.swift`. Part library: `SceneParts.swift`. Whole objects: `SceneMacros.swift`. Maths: `SceneGeometry.swift`. Label chips: `SceneLabelLayout.swift`
- The camera that directs itself: `SceneCamera.swift` (framing maths, calm-movement rules, which parts a sentence is about) and `SceneRefine.swift` (refine or redraw, the refine prompt, `detail`), both pure
- Voice turn to drawing: `Core/SceneDirector.swift` (`show`, `refine`, `annotate`, `stop`)
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

`say N "sentence"` gives the sentence to speak and ties the lines after it to sentence N. `@N` does the same without text (alone on a line, or as a prefix: `@3 ring …`). With speech, a line is drawn when the host calls `sentenceStarted(index: N)`. Without speech, lines are drawn in order about 0.09 s apart with a half-second pause between sentences. A sentence that never starts is released after `SceneAnchor.maximumHold` seconds (8 by default; `SceneDirector` sets 120 because it always reports each sentence or the end of speech).

The prompt asks for 3–6 short spoken sentences, each followed at once by at least one line that draws, labels or moves what the sentence is about.

### How the drawing narrates itself

`SceneDirector.show(_:)` makes one model call. The model writes the narration into the script as `say` lines. With speech timing a `say` line is handed to the host (`onSay`) the moment it arrives, so the voice can start; the drawing lines after it wait in the scheduler. `SceneNarrationSequencer` (pure, in `SceneNarration.swift`) speaks one sentence at a time in arrival order:

| Situation | What happens |
|---|---|
| The stream is ahead of the voice (usual: the script arrives in 2–4 s, speaking it takes 10–20 s) | Sentences queue. Each sentence's lines appear when that sentence starts being spoken. |
| The stream is behind the voice | The voice waits for the next `say`. Lines that arrive after their sentence started are drawn at once. |
| No `say` lines, or no `speak` callback | Lines are drawn a beat apart. Marks on the screen stay at least 5 s. |
| Barge-in (`SceneDirector.shared.stop()`) | The stream and the speech callback are cancelled. Lines already received are drawn at once so a card or model is not left half built, marks on the screen fade, cards and 3D stay. |
| Speech ends | Anything still waiting is drawn, then marks on the screen fade (cards and 3D stay). |

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

Options on any of them: `color=`, `w=` stroke width, `dash`, `fill` (hatching), `label="…"` (a pill beside the shape), `for=seconds`. Shapes stay while Teachy speaks and fade when the host calls `speechEnded()`. A highlight fades by itself after 2 s.

**Drawing on the real screen.** `SceneDirector.shared.annotate(question:screenshotJPEG:displayFrame:)` sends the screenshot with `SceneScriptPrompt.annotateSystem`, which offers only these verbs, and drops any other line (`SceneSession.commandFilter`). The overlay window covers `displayFrame` (the AppKit frame of the display the screenshot shows), so 0–1000 lands on that display on any monitor arrangement. The mapping is `SceneScreenMapping` (pure, in `SceneNarration.swift`): x runs across the frame, y is measured down from the frame's top edge.

### Card (a floating sheet of grid paper)

```
card c title="The chain rule"
text "…"            bullet "…"            formula "dy/dx = dy/du × du/dx"
steps "x" "u = 3x² + 1" "y = ln u"        (or steps items="A > B > C")
chart ch type=bar|line|point data=1,4,9 labels="a|b|c" title="…" x="…" y="…"
image query="GE9X turbofan" caption="…"   (a real photo, with a small "source" link under it)
chip "A follow-up question"
```

Lines go to the most recent `card`. A second `card` with a new id opens a second window.

**Photos.** `ScenePhotoFetcher` finds the picture on its own task, so the card keeps filling in while it loads. Order: the disk cache (`~/Library/Caches/<bundle id>/scene-photos/<key>.img` plus a `.json` note of the source page); publik `POST /search` (its results have no image fields as of 14 Nov 2026, so this only tells us which Wikipedia article the phrase means; an image field is used if one ever appears); Wikipedia's page summary for that article or for the phrase itself; Wikipedia's title search. Downloads are HTTPS only, JPEG/PNG/WebP/GIF only, 6 MB at most. `ScenePhotoPicker` is the pure half.

### 3D model (a transparent window you can turn)

`scene3d id title="…"` opens it. Y is up. Units are whatever the script likes: the camera fits the model, then follows the narration (see "The camera" below). Clicking a part calls `onPartTapped(id, label)`; double-clicking one puts the camera on it.

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

A leading list number in a label moves to the dot (`"1. Fan"`, or `"1 Fan"` with `n=1`). A number that is part of the name stays (`"3 Na⁺ out"`, `"2 stroke engine"`).

**Where chips go** (`SceneLabelLayout`, pure): a wide model gets a row of chips above it, and a second row below when the first is full; a tall or squarish model gets a column of chips each side. Chips never overlap, they keep the order of the parts they point at so leaders do not cross, and each leader ends on the part itself (found by hit-testing, because the middle of a cable or a hollow casing is thin air). The camera frames the model and its chips together. `side=` on a label overrides the choice.

Whole objects (`SceneMacros.swift`). One line expands into the shapes and ready-made parts below, as children of a group with the line's id. Label a piece with `label x on=id.piece text="…" n=1`, or add the flag `labels` to label the main pieces in order. They take `at=` `rot=` `axis=` `scale=` `color=`.

| Verb | What you get | Pieces (`id.…`) |
|---|---|---|
| `jet id stages=4 rpm=` (`turbofan`) | a cutaway turbofan with spinning fan, compressor and turbine, and the bypass and core air streams | `fan compressor combustor turbine nozzle nacelle casing bypass core exhaust` |
| `engine id cylinders=4 rpm= bore= stroke=` | an inline piston engine: pistons firing in order on one crankshaft, flywheel, see-through block | `p1…pN crankshaft flywheel block pan` |
| `rocket id stages=1…3 h=` | nose cone, stages with interstages, fins, engine bell and flame (`explode id axis=y` shows staging) | `nose stage1 stage2 stage3 interstage fins engine flame` |
| `bridge id span=` | a suspension bridge: deck, two towers, main cables, hangers, anchorages, water | `deck cable cable2 hangers tower1 tower2 anchor1 anchor2` |
| `heart id bpm=` | a beating diagram heart, blue for oxygen-poor and red for oxygen-rich, with the blood's path | `ra rv la lv aorta pulmonary venacava veins` |
| `eye id` | an eyeball cut open along its axis, with light rays to the retina | `sclera retina cornea iris lens nerve` |
| `motor id rpm=` | a brushed DC motor in a cut-open can | `housing north south rotor shaft commutator brushes` |
| `battery id` (`cell`) | an alkaline cell cut open | `case jacket cathode separator anode collector positive negative` |
| `membrane id size=w,d` | a patch of lipid bilayer | (the group) |
| `protein id on=membraneId at=x,z r= h=` (`pump`, `channel`) | a protein through the membrane, cut open to show its pore | (the part) |
| `planet id r= dist= period= around=sunId moons=1 ring` | a body and its orbit; with no `dist=` it is the body in the middle (a `sun` glows) | `id.moon id.ring` |
| `pendulum id length= angle= mass=` | pivot, support, bob and joint. The joint has the id, so `bind=id.length` and `of=id.angle` work | `bob pivot beam` |
| `pins id on=boardId at=x,z count=40 rows=2` (`gpio`, `header`) | rows of gold pins on a black strip | (the part) |

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
| `board id size=w,d` then `comp id on=board at=x,z size=w,d[,h] label="…"` | a flat board with blocks sitting on it. A block is dressed from `kind=` or from words in its id and label: `usb`, `ethernet`, `hdmi` (metal shell, dark opening toward the nearest board edge), `chip` (CPU, RAM…: black body, metal lid), `header` (GPIO: gold pins), `sd`, `connector` (camera, display) |
| `chain id a=gearA b=gearB` (`belt`) | a chain round two gears, with links that travel at the driving gear's rim speed. The gears then turn the same way at the ratio of their teeth |
| `axes id size=` | X, Y, Z arrows |

Motion (the id is the part that moves):

```
spin partId rpm= axis=            move partId to=x,y,z dur=2 loop     (or by=)
pulse partId                      explode [groupId] axis=x dist=1     (dist=0 puts it back)
beat partId bpm=60 amount=0.08    (a quick squeeze, then rest: a heart, a pulsing cell)
orbit partId around=otherId r= period= tilt=
camera to=x,y,z look=x,y,z dur=   remove id / clear
```

### The camera

```
focus id[,id…] zoom=tight|medium|wide dur=     ease onto those parts (their combined box, with room round it)
frame all                                       back to the whole model (frame id… is a wide focus)
frame all hold                                  keep the fitted overview for this narration cue
orbit id deg=120 dur=4                          a slow arc round a part (orbit all: round the model)
ghost id id… opacity=0.14 / ghost others / ghost none      see-through, to show what is inside (alias: cutaway)
hide id id… / show id id… / show all            show all also undoes every ghost
highlight id color=yellow / highlight none      a soft glow that breathes; cleared by the next focus or frame
detail id                                       a richer sub-assembly with its own labels (see below)
```

`zoom` is the share of the picture's shorter side the parts fill: tight 66%, medium 50%, wide 34%. `orbit` with `around=`, `period=` or `r=` is still a planet's orbit; `highlight` with `from=`/`to=` is still a swipe on the screen.

**Where it looks from.** A focus keeps the opening 3/4 view when the part can be seen from there. Otherwise it tries a handful of other sides (a little left and right, higher, further round) and takes the clearest, asking SceneKit what a few lines of sight to the part really hit (so a cutaway counts as open and a shell as closed). A flat part is not shown edge on. If the part is hidden from every side, what stands in front of it is ghosted until the camera moves on.

**It follows the narration.** When a sentence starts and none of its own lines moves the camera, the engine works out what the sentence is about: the parts its lines label, else the parts they pulse, spin, move or highlight, else the one or two parts they create, else the parts whose label, name or id words are in the sentence (`SceneSubjectMatcher`: case and plurals ignored, the longest label wins, little and general words pick nothing). It then eases onto them at medium zoom. Rules:

| Rule | Value |
|---|---|
| Ease in, ease out | every move; 0.85–1.8 s depending on how far |
| Dwell | a move starts no sooner than 1.2 s after the one before (`SceneCameraPolicy.minimumDwell`) |
| One move per sentence | always |
| Already in view | a subject that is all in the picture, about the right size and not hidden gets a blink instead of a move |
| Opening sentence | shows the whole model for 1.3 s; if it has 8 or more words and singles out a part, the camera then goes in on it |
| No subject | eases back to the whole model |
| End of the narration | the whole model. A `frame all` on a last sentence that labels a part of its own is kept for the end, so the part is shown while it is talked about |
| The person is steering | nothing moves the camera until they have been idle 5 s (`gesturePause.idleResume`); never during a gesture |

**Conceptual diagrams.** Use `frame all hold` in every narration cue to keep an overview that fits new nodes and labels as they appear. Unlike plain `frame all`, it is not deferred to show a part close-up. This avoids cropped layouts from guessed numeric camera positions.

Lines the engine writes itself (`focus … auto`, `frame all auto`, `pulse … auto`, a double-click's `focus`, Recenter's `frame all`) go into the log like any other, so a replay or a saved video repeats them without working anything out again. `SceneSession.directsCamera = false` switches all of this off (the camera then only frames the whole model, as it used to).

**The person's hands.** Drag turns the model; option-drag, right-drag or Shift with a scroll slides it; scrolling (mouse wheel, two fingers on a trackpad, a Magic Mouse) and a pinch zoom toward the cursor; double-click a part to focus it; double-click empty space, Escape or the Recenter button (shown whenever the view is not the default) goes back to the whole model and lets the camera direct itself again. Escape reaches the model once it has been clicked: the model's view asks for its non-activating panel to become key (`needsPanelToBecomeKey`), so the person's app stays the active app and gets the keyboard back when they click in it. Zoom stops short of the first solid surface ahead and at three times the whole-model distance, and the model cannot be slid out of the picture. A single click on a part is reported after the double-click wait (at most 0.3 s).

**Labels when zoomed.** Chips are laid out toward the edges of the picture and keep the same size at every zoom. A chip is hidden when its part is hidden, ghosted or out of the picture; the focused part always keeps its own. The labels `detail` added are put away by `frame all` (so by "go back" and Recenter) and come back when the part is detailed again. A leader to a part that spins lands on its axle; a leader to a piece of a spinning part (one blade) is held in that piece's own space, so it goes round with it every frame.

**Which side.** Besides what is in the way and edge-on views, a part toward one end of the model is looked at from its own end (the fan from the intake, not from across the engine).

**`detail id`** adds finer pieces and names them. It does something for: a `fan` (splitter blades, blade roots, shaft), a group of fan stages such as a jet's `compressor` or `turbine` (still stator vanes between the stages, rotor blades, disc, shaft), a `gear` (hub, axle, key, pitch circle), a `piston` (rings, wrist pin, every piece named), a `wheel` (brake disc, caliper, nuts), a board `comp` (legs, pin 1), a heart chamber (its valve) and `dna` (backbone and base pair named). On anything else it does nothing.

**Big scenes.** Hundreds of identical unnamed pieces made by one whole-object line (a membrane's lipids) share low-detail geometry and are merged into one node (`<id>._bulk`), one draw per colour. Past `Scene3DController.maximumNodes` (3200), small unnamed pieces stop being added; named parts always are.

### Refining instead of redrawing

When a 3D model is up and `SceneDirector.show(_:)` gets a request about it, nothing is drawn again. `SceneRefineClassifier` (pure) decides: camera words ("zoom", "inside", "rotate", "explode", "go back"…), a part asked about by colour, a part of the model named, or a short request about "it" refine; a request to draw something, "instead", or a thing this model does not have is a new drawing; when nothing ties the request to the model, a new drawing. `SceneDirector.refine` then

1. moves the camera at once when the request says plainly where to look (`SceneRefineClassifier.instantScript`: the named part, or for "go back" the whole model put back together: `explode dist=0`, `show all`, `highlight none`, `frame all`),
2. sends the model `SceneRefinePrompt.system` with the scene in words (`Scene3DController.liveState`: each part's id, name, colour, what it sits inside, whether `detail` has something to add, what is ghosted or hidden, where the camera is, whether it is exploded),
3. applies the answer to the live scene through `SceneSession.beginRefinement`. Only camera, visibility, label, motion and `say` lines and a few small shapes are let through (`SceneRefinePrompt.allows`); anything that would rebuild the model is dropped. The lines are added to the same log.

When the answer has been spoken, `SceneDirector.onRefinementAnswered(question, spokenAnswer)` hands it to the voice turn so it is kept in the conversation. A refined drawing is saved over the drawing it came from (`SceneHistory.update`: the log with the refinement's lines appended, a new picture, the old video removed), including a drawing played from the Drawings list.

A tap on a part is a refinement too: the camera goes to the part and highlights it at once, and the model says one or two sentences about it. (Before, a tap went out through `onFollowUpQuestion` and the drawing was drawn again. Follow-up chips still go out that way.) `SceneDirector.refinesInPlace = false` restores the old behaviour.

Scripted speeds above 240 rpm (150 for pistons) are capped so the motion can be seen.

`explode`: the axis is a world direction (it is turned into the space the parts live in, so a model lying on its side comes apart the way the script says). With no axis, parts go the way they are spread, and flat layers on one spot separate along their thin side. Parts that sit on a base (components on a board) lift off it; none are pushed through it. A scene that is one object (a board with its parts, or one whole-object macro) is opened without naming it.

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

Slider targets: `gravity`, `speed` (time scale), `jointId.length`, `bodyId.mass`, `bodyId.bounce`, `partId.rpm` (an `engine` id sets all its pistons), `orbitId.period`, `orbitId.r`, `springId.k`, `springId.rest`, `partId.x|y|z`, `partId.scale`, `partId.opacity`. With no property the obvious one is used (a joint's length, a body's mass, otherwise rpm).

Plot properties: `x`, `y`, `z`, `speed`, `angle` (of a body hanging from a joint, in degrees), `rpm`.

How each thing is simulated:

| Thing | Method |
|---|---|
| Falling, bouncing, colliding bodies; pendulums and other jointed bodies | SceneKit physics |
| Gears | Kinematic: rpm spreads through the train (driven = −driver ÷ ratio) |
| Orbits, pistons, flow | Kinematic, advanced every frame |
| A body on a `spring … k=` | The engine's own integrator (semi-implicit Euler, 8 steps a frame). SceneKit's solver gained energy with stiff springs |

## Hosting

The app goes through `SceneDirector` (`leanring-buddy/Core/SceneDirector.swift`):

```swift
// Once, when the voice turn is set up:
SceneDirector.shared.speak = { sentence in await voice.speak(sentence) }      // returns when the sentence has been spoken
SceneDirector.shared.cancelSpeech = { voice.stop() }
SceneDirector.shared.onFollowUpQuestion = { question in ask(question) }       // a chip or a 3D part was tapped

SceneDirector.shared.show("how a turbofan works")                              // [SHOW: …]
SceneDirector.shared.annotate(question: "circle the bug", screenshotJPEG: jpeg, displayFrame: frame)   // [MARK: …]
SceneDirector.shared.stop()                                                    // barge-in
```

- Without `speak`, nothing is spoken and lines appear a beat apart (stagger timing), as before.
- Follow-ups keep context. When a drawing finishes, its `SceneReplayLog.summary` (title, kind, objects and labelled parts by id, what was said) is kept for ten minutes and sent with the next `show` request, so "show it in 3D" or "what does the turbine do" builds on it. Tapping a part asks `In the drawing "<title>", tell me about the <part>.`
- `SceneDirector.voicePromptRules` is the text that tells the voice model when to use `[SHOW: …]` and when `[MARK: …]`.

Underneath is `SceneSession`, which any host can drive directly:

```swift
let scene = SceneSession()
scene.onPartTapped = { id, label in ask("Tell me about the \(label)") }
scene.onChipTapped = { question in ask(question) }
scene.photoFetcher = { query in await photos.photo(for: query) }
scene.onSay = { index, text in speakLater(index, text) }      // with speech timing: called as each `say` arrives
scene.begin(anchor: .display(frame: screenshotDisplayFrame, timing: .speech))
for try await delta in contentDeltas(of: stream) { scene.feed(chunk: delta) }
scene.end()
// from the speech engine
scene.sentenceStarted(index: n)
scene.speechEnded()
```

- Hosts with their own overlay set `anchor.hostsOverlay = true` and draw `SceneOverlayView(model: scene.overlayModel, mapping: rect)`.
- `scene.interrupt()` is barge-in at the session level; `scene.onFinished` fires once when the stream has ended and every line is drawn.
- `scene.replay()` plays the drawing again with its original timing. `scene.log.encoded()` saves it; `scene.replay(saved, anchor:)` loads it. Slider drags are in the log.

## Replay, video and history

- **Camera in replays.** Camera moves, ghosting, hiding, highlights and `detail` are ordinary log lines, so `replay()` and the video exporter reproduce them; the automatic ones were written into the log when they happened. The camera's own gestures by hand (drag, wheel, pinch) are not recorded; a double-click and Recenter are.
- **Video.** `scene.exportMP4(to:)` (or `SceneVideoExporter.export(log:narration:to:options:)`) writes an H.264 MP4, 1920×1080 at 30 fps by default. Nothing is captured from the screen: the log is played into a headless scene (`SceneAnchor.headless`) and each frame is drawn in-process, the 3D model by an `SCNRenderer` whose clock is the frame number, cards and controls by `ImageRenderer`, marks by `SceneOverlayView` with a frozen clock. The same log gives the same video. Measured on this Mac (14 Nov 2026): 2.2 s of 1080p video of a labelled turbofan with a card rendered in 1.0 s.
- **Voice in the video.** The exporter muxes an AAC track when the session was given the narration: `SceneDirector.shared.appendNarrationAudio(pcm16, sampleRate:)` (mono 16-bit PCM, as the realtime voice produces it). Chunks are laid on the scene's clock where they arrive. Nothing in the app forwards that audio yet, so videos are silent until the voice does.
- **History.** Each finished `show` drawing is saved to `~/.teachy/drawings/<yyyy-MM-dd>-<id>/`: `meta.json` (title, question, date, length), `scene.json` (the log), `thumb.png`, `narration.pcm` when there is a voice, and `video.mp4` the first time it is exported. The newest 200 are kept. `SceneHistory.shared.entries`, `replay(id)`, `export(id) async throws -> URL`, `delete(id)`. `SceneHistoryStore` is the plain file half.
- **Drawings card.** `DrawingsSection()` is the Home-tab card: a grid of thumbnails with Replay and Save video.

## Tests and eval

- `scripts/tests/run_scene_tests.sh`: parser, fuzzing, geometry, part library, scheduler, replay log.
- `scripts/tests/run_scene2_tests.sh`: whole-object macros, label layout, explode and label-number fixes, narration sequencing, screenshot coordinates, narration audio, summaries, quality score, photo picking, history store (pure); then, in-process with windows off every display: speech-synced building and barge-in on a live session, real mouse events into the 3D view and a slider, MP4 export, history and the Drawings card, photos. `--network` also fetches real photos.
- `scripts/tests/run_scene3_tests.sh`: the self-directing camera. Pure: subject matcher, refine classifier, framing maths, choice of side with made-up occluders, dwell and skip rules, the gesture pause on an injected clock, the new verbs, `detail`, log round trip. In-process: focus, orbit, ghost, highlight and detail on a real model off screen; the camera following a narration; refining in place; a recorded scene replayed frame for frame and exported; real NSEvents (drag, option-drag, wheel, trackpad scroll, pinch, double-click, click, Escape) into a window placed off every display; merged pieces and the node budget. `--perf FILE…` prints frame times.
- `scripts/eval/run_scene_eval.sh`: twelve prompts through `TeachyAIRouter`, one call each, with latency and a crude quality score (`SceneQuality`), then what the camera does with each answer (played off screen with a stand-in voice: is the camera on the sentence's part, is the part fully in view at 20–75% of the shorter side, is it hidden, are the labels in the picture), then six refine cases through `SceneDirector` with their latency. `--score DIR` measures saved answers again without model calls, `--no-direct` with the camera as it used to be, `--shots a,b` writes a picture per sentence to `$TMPDIR/teachy-scene3/shots/<scene>/NN.png`.
- `scripts/eval/run_annotate_eval.sh`: ten made-up screenshots with a known target each; a hit is the model's first mark landing on the target.
- `scripts/tests/scene2/render/main.swift`: renders script files to PNG without the app.
