//
//  SceneDemo.swift
//  leanring-buddy / Scene
//
//  A way to see the drawing engine without a model: built-in sample scripts and
//  a debug launch mode.
//
//      TEACHY_SCENE_DEMO=turbofan  Teachy.app/Contents/MacOS/Teachy
//
//  shows that sample and nothing else (no sign-in, no menu bar), writes PNG
//  snapshots to $TMPDIR/scene-shots/, and quits after TEACHY_SCENE_DEMO_SECONDS
//  (default 8). Other switches, all optional:
//
//      TEACHY_SCENE_DEMO_SCRIPT=/path/to/file   show a script file instead of a sample
//      TEACHY_SCENE_DEMO_TAP=partID             click that part part-way through
//      TEACHY_SCENE_DEMO_WATCH=partID           print that part's position twice a second
//      TEACHY_SCENE_DEMO_SET=slider:value       move a slider part-way through
//      TEACHY_SCENE_DEMO_REPLAY=1               replay the scene part-way through
//

import AppKit

@MainActor
enum SceneDemo {
    private static var session: SceneSession?
    private static var timers: [Timer] = []

    /// Shows a script as if a model were streaming it.
    @discardableResult
    static func show(script: String, timing: SceneCueScheduler.Timing = .stagger) -> SceneSession {
        let session = SceneSession()
        session.onPartTapped = { id, label in print("🎨 SceneDemo: tapped part \(id) (\(label))") }
        session.onChipTapped = { text in print("🎨 SceneDemo: tapped chip \(text)") }
        session.onSay = { index, text in print("🎨 SceneDemo: say \(index): \(text)") }
        session.imageFetcher = { query in await placeholderPhoto(for: query) }
        session.begin(anchor: .mainDisplay(timing: timing))
        self.session = session

        // Arrive in small pieces, like tokens.
        let characters = Array(script)
        var index = 0
        let timer = Timer(timeInterval: 0.012, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard index < characters.count else {
                    timer.invalidate()
                    session.end()
                    return
                }
                let end = min(index + 28, characters.count)
                session.feed(chunk: String(characters[index..<end]))
                index = end
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
        return session
    }

    static func show(sample name: String) -> SceneSession? {
        guard let script = samples[name] else { return nil }
        return show(script: script)
    }

    /// When launched with TEACHY_SCENE_DEMO, shows only the demo and returns true.
    static func runFromEnvironmentIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["TEACHY_SCENE_DEMO"], !name.isEmpty else { return false }
        NSApp.setActivationPolicy(.accessory)

        var script = samples[name]
        if let path = environment["TEACHY_SCENE_DEMO_SCRIPT"], let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            script = contents
        }
        guard let script else {
            print("🎨 SceneDemo: no sample named \(name). Samples: \(samples.keys.sorted().joined(separator: ", "))")
            NSApp.terminate(nil)
            return true
        }
        let seconds = Double(environment["TEACHY_SCENE_DEMO_SECONDS"] ?? "") ?? 8
        let session = show(script: script)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scene-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func after(_ delay: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
        func snap(_ suffix: String) {
            for (surface, image) in session.snapshots() {
                let url = folder.appendingPathComponent("\(name)-\(surface)-\(suffix).png")
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                    print("🎨 SceneDemo: wrote \(url.path)")
                }
            }
        }

        after(seconds * 0.5) { snap("a") }
        after(seconds - 0.6) {
            snap("b")
            let stats = session.parseStats
            print("🎨 SceneDemo: \(stats.commands)/\(stats.contentLines) lines parsed, \(session.partCount) 3D parts, log \(String(format: "%.1f", session.log.duration)) s")
            for rejection in session.parseRejections { print("🎨 SceneDemo: skipped \(rejection)") }
        }
        if let part = environment["TEACHY_SCENE_DEMO_TAP"] {
            after(seconds * 0.6) { session.modelWindow?.controller.simulateTap(onPart: part) }
        }
        if let setting = environment["TEACHY_SCENE_DEMO_SET"]?.split(separator: ":"), setting.count == 2, let value = Double(setting[1]) {
            after(seconds * 0.55) { session.modelWindow?.controller.setSlider(String(setting[0]), value: value, fromUser: true) }
        }
        if environment["TEACHY_SCENE_DEMO_REPLAY"] != nil {
            after(seconds * 0.55) {
                print("🎨 SceneDemo: replaying \(session.log.entries.count) commands")
                session.replay()
            }
        }
        if let part = environment["TEACHY_SCENE_DEMO_WATCH"] {
            let began = Date()
            let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let controller = session.modelWindow?.controller else { return }
                    if let state = controller.debugState(of: part) {
                        let spin = controller.debugSpinAngle(of: part).map { String(format: " spin=%.2f", $0) } ?? ""
                        print(String(format: "🎨 SceneDemo: t=%.2f %@ pos=(%.3f, %.3f, %.3f) speed=%.3f%@", Date().timeIntervalSince(began), part,
                                     state.position.x, state.position.y, state.position.z, state.speed, spin))
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        after(seconds) {
            session.clear()
            NSApp.terminate(nil)
        }
        return true
    }

    /// A drawn stand-in so cards with photos can be checked offline.
    private static func placeholderPhoto(for query: String) async -> NSImage? {
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [NSColor(calibratedRed: 0.55, green: 0.74, blue: 0.93, alpha: 1), NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.62, alpha: 1)])?
            .draw(in: CGRect(origin: .zero, size: size), angle: -60)
        let text = NSAttributedString(string: query, attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.white])
        text.draw(at: CGPoint(x: 24, y: 24))
        image.unlockFocus()
        return image
    }

    // MARK: - Samples

    static let samples: [String: String] = [
        "turbofan": turbofan, "dna": dna, "gears": gears, "pendulum": pendulum, "card": card, "overlay": overlay,
        "piston": piston, "solar": solar, "bounce": bounce, "board": board, "spring": spring,
    ]

    static let turbofan = """
    say 1 "A turbofan is a huge fan wrapped around a small jet engine."
    scene3d jet title="How a turbofan works"
    lathe nacelle axis=x pts=1.36,-2.5;1.52,-2.1;1.56,-0.6;1.34,0.9;1.26,0.9;1.44,-0.6;1.40,-2.1;1.36,-2.5 sweep=215 color=white
    cyl shaft from=-2.0,0,0 to=2.4,0,0 r=0.1 color=steel
    fan fan at=-1.95,0,0 axis=-x r=1.34 blades=20 hub=0.42 rpm=28 color=steel label="Fan" n=1
    say 2 "Most of the air skips the core and is simply pushed back. That bypass air makes most of the thrust."
    flow bypass pts=-3.6,1.0,0.5;-1.9,1.05,0.5;0,1.02,0.5;2.0,0.98,0.5;3.8,0.95,0.5 color=sky
    say 3 "The rest is squeezed by the compressor, then burned in the combustor."
    lathe core axis=x pts=0.60,-1.25;0.74,-0.95;0.74,1.5;0.52,2.3;0.44,2.3;0.64,1.5;0.64,-0.95;0.60,-1.25 sweep=215 color=silver
    fan c1 at=-0.95,0,0 axis=-x r=0.62 blades=16 hub=0.22 rpm=70 color=blue label="Compressor" n=2
    fan c2 at=-0.62,0,0 axis=-x r=0.60 blades=16 hub=0.26 rpm=70 color=blue
    fan c3 at=-0.30,0,0 axis=-x r=0.58 blades=16 hub=0.30 rpm=70 color=blue
    torus burner at=0.42,0,0 axis=x r=0.36 r2=0.17 color=orange glow label="Combustor" n=3
    flow coreair pts=-3.6,0.36,0.25;-1.2,0.38,0.25;0.3,0.36,0.25 color=sky
    say 4 "Hot gas spins the turbine, which drives the fan up front, and leaves through the nozzle."
    fan t1 at=1.10,0,0 axis=-x r=0.62 blades=18 hub=0.24 rpm=70 color=copper label="Turbine" n=4
    fan t2 at=1.45,0,0 axis=-x r=0.58 blades=18 hub=0.24 rpm=70 color=copper
    cone nozzle at=2.55,0,0 axis=x r=0.34 r2=0.06 h=0.9 color=steel label="Nozzle" n=5
    flow exhaust pts=0.7,0.36,0.25;1.6,0.36,0.25;2.6,0.42,0.25;3.9,0.4,0.25 color=orange
    arrow3 thrust from=2.6,-1.75,0 to=-1.6,-1.75,0 color=orange r=0.07
    text3 thrustword at=0.5,-2.25,0 text="Thrust" color=orange size=0.5
    chip "Why is the fan so big?"
    chip "What does the turbine do?"
    """

    static let dna = """
    say 1 "DNA is two strands wound around each other in a double helix."
    scene3d helix title="DNA double helix"
    dna d turns=2.5 r=1
    spin d rpm=5 axis=y
    say 2 "The rails are sugar and phosphate. The rungs are pairs of bases."
    label l1 on=d.strand1 text="Sugar-phosphate backbone" n=1
    label l2 on=d.b12a text="Base pair" n=2 side=right
    say 3 "A always pairs with T, and G with C. That is how the code is copied."
    chip "How is DNA copied?"
    chip "What is a gene?"
    """

    static let gears = """
    say 1 "A small gear driving a big one trades speed for turning force."
    scene3d train title="Gear train 3 : 1"
    gear drive teeth=12 r=0.8 color=orange rpm=30 label="Driver, 12 teeth" n=1
    gear big teeth=36 mesh=drive color=blue label="Driven, 36 teeth" n=2
    say 2 "Three turns of the small gear make one turn of the big one, in the opposite direction."
    gear idler teeth=18 mesh=big angle=55 color=teal label="Idler" n=3
    slider speed min=0 max=120 value=30 label="Driver rpm" bind=drive.rpm
    plot out of=big.rpm label="Output rpm" color=blue
    chip "Why does it turn the other way?"
    """

    static let pendulum = """
    say 1 "A pendulum swings because gravity keeps pulling the bob back to the middle."
    scene3d p title="Pendulum"
    box beam at=0,3.08,0 size=2.4,0.12,0.5 color=brown
    fixed pivot at=0,3,0
    body bob shape=sphere r=0.28 mass=1 at=1.5,1.3,0 color=red label="Bob"
    joint ball rope a=pivot b=bob
    say 2 "Make the rope longer and it swings more slowly. Change gravity and watch again."
    slider len min=0.6 max=3 value=2.3 label="Length" bind=rope.length
    slider g min=1 max=25 value=9.8 label="Gravity" bind=gravity
    plot swing of=bob.angle label="Angle"
    chip "Why doesn't mass matter?"
    """

    static let card = """
    say 1 "Powerful, for a jet engine, means how hard it can push."
    card c1 title="Engine performance"
    text "What 'powerful' means:"
    formula "Thrust ≈ airflow × speed gain"
    steps "Suck" "Squeeze" "Burn" "Blow"
    say 2 "Bigger fans move far more air, which is why thrust has grown so much."
    chart thrust type=bar data=97,121,311,513 labels="CFM56|V2500|Trent 900|GE9X" title="Take-off thrust (kN)"
    image query="GE9X turbofan engine" caption="GE9X, the largest fan flying"
    bullet "Move more air, a little faster"
    bullet "Not less air, a lot faster"
    chip "What is bypass ratio?"
    chip "Show it in 3D"
    """

    static let overlay = """
    say 1 "Start with the search box at the top."
    ring r1 at=500,120 r=70 color=red label="Type here"
    arrow a1 from=300,330 to=440,170 bend=0.25 color=red
    say 2 "These three settings are the ones that matter."
    rect box1 from=90,420 to=410,640 color=blue dash label="Settings"
    highlight h1 from=110,470 to=380,510
    poly p1 pts=620,420;860,440;900,640;700,690;580,560 color=green fill label="Triangle area"
    line l1 pts=600,800;680,760;760,820;840,770;920,810 color=purple smooth
    label t1 at=760,870 text="then follow this path"
    arrow a2 from=560,300 to=820,300 color=orange label="drag right"
    rect box2 from=120,720 to=380,880 color=orange fill
    """

    static let piston = """
    say 1 "In a piston engine, burning fuel pushes the piston down."
    scene3d eng title="Piston engine"
    piston p1 bore=1 stroke=1.1 rpm=45 color=steel label="Piston" n=1
    say 2 "The connecting rod turns that push into rotation of the crankshaft."
    label lrod on=p1.rod text="Connecting rod" n=2 side=right
    label lcrank on=p1.crank text="Crank" n=3 side=left
    slider rpm min=5 max=200 value=45 label="Engine rpm" bind=p1.rpm
    chip "What are the four strokes?"
    """

    static let solar = """
    say 1 "The planets closer to the sun go round faster."
    scene3d sys title="Inner solar system"
    sphere sun r=0.7 color=yellow glow label="Sun"
    sphere mercury r=0.12 at=1.4,0,0 color=gray
    sphere venus r=0.2 at=2.1,0,0 color=gold
    sphere earth r=0.22 at=3,0,0 color=blue label="Earth"
    sphere moon r=0.07 at=3.45,0,0 color=silver
    sphere mars r=0.16 at=4,0,0 color=red label="Mars"
    orbit mercury around=sun period=2.4
    orbit venus around=sun period=6.2
    orbit earth around=sun period=10
    orbit moon around=earth r=0.45 period=1.2
    orbit mars around=sun period=18.8
    slider year min=2 max=30 value=10 label="Earth year (s)" bind=earth.period
    chip "Why do inner planets move faster?"
    """

    static let bounce = """
    say 1 "Drop three balls. The bouncier the ball, the more of its speed it keeps."
    scene3d drop title="Bounce"
    ground y=0 size=7
    body b1 shape=sphere r=0.3 at=-1.2,3,0 color=red bounce=0.9 label="Rubber"
    body b2 shape=sphere r=0.3 at=0,3,0 color=blue bounce=0.6
    body b3 shape=box size=0.5,0.5,0.5 at=1.2,3.4,0 color=teal bounce=0.2 vel=0.4,0,0
    slider g min=1 max=25 value=9.8 label="Gravity" bind=gravity
    plot h of=b1.y label="Height"
    """

    static let board = """
    say 1 "This is the layout of a small single-board computer."
    scene3d pi title="Single-board computer"
    board pcb size=8.5,5.6
    comp cpu on=pcb at=-0.6,0.2 size=1.5,1.5 color=silver label="Processor" n=1
    comp ram on=pcb at=1.3,0.3 size=1.1,1.3 color=black label="Memory" n=2
    comp usb1 on=pcb at=3.5,-1.6 size=1.7,1.3,1.4 color=silver label="USB ports" n=3
    comp usb2 on=pcb at=3.5,0 size=1.7,1.3,1.4 color=silver
    comp eth on=pcb at=3.5,1.7 size=1.9,1.5,1.3 color=silver label="Ethernet" n=4
    comp gpio on=pcb at=-0.8,-2.45 size=5.2,0.5,0.75 color=black label="GPIO pins" n=5
    comp sd on=pcb at=-3.9,0 size=0.9,1.3,0.12 color=gold label="microSD" n=6
    chip "What do the GPIO pins do?"
    """

    static let spring = """
    say 1 "A mass on a spring bobs up and down. A stiffer spring bobs faster."
    scene3d sm title="Mass on a spring"
    box ceiling at=0,3.1,0 size=2,0.14,0.8 color=brown
    fixed top at=0,3,0
    body mass shape=box size=0.6,0.6,0.6 mass=1 at=0,0.9,0 color=blue label="Mass"
    spring coil a=top b=mass k=30 rest=1.4 r=0.2 coils=10
    slider k min=5 max=120 value=30 label="Stiffness" bind=coil.k
    plot y of=mass.y label="Height"
    """
}
