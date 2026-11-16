import AppKit
import Foundation

// No credentials, screenshots, user history or network requests are used by this test.
let testRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-annotation-lifecycle-\(UUID().uuidString)")
setenv("TEACHY_DRAWINGS_DIR", testRoot.path, 1)
setvbuf(stdout, nil, _IONBF, 0)
var checks = 0
var failures = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL: \(message)") }
}
func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

@MainActor
func run() async {
    let director = SceneDirector.shared
    director.placement = { anchor in
        anchor.hostsOverlay = true
        anchor.modelTopLeft = CGPoint(x: -30000, y: -30000)
        anchor.cardTopLeft = CGPoint(x: -30000, y: -30000)
    }
    director.speechLeadTime = 0
    let display = CGRect(x: -1440, y: 120, width: 1440, height: 900)
    var anchor = SceneAnchor.display(frame: display, timing: .stagger)
    director.placement?(&anchor)
    director.scene.begin(anchor: anchor)
    director.scene.feed(chunk: "scene3d model title=\"Existing diagram\"\nbox node at=0,0,0 label=\"Name\"\ncard notes title=\"Existing notes\"\ntext \"Keep this text\"\n")
    director.scene.end()
    await pause(1)
    guard let model = director.scene.modelWindow, let card = director.scene.cards.first else {
        print("FAIL: fixture did not build its model and card")
        exit(1)
    }
    director.adoptSavedDrawing("saved-fixture")
    let savedLog = director.scene.log
    let savedSummary = director.lastSummary
    let savedAudio = director.scene.narration
    let historyCount = SceneHistory.shared.entries.count
    var spoken: [String] = []
    director.speak = { text in spoken.append(text); await pause(0.05) }
    director.beginAnnotation(question: "Circle Name", displayFrame: display)
    director.annotationScene.feed(chunk: "say 1 \"Here is the name.\"\nring name at=500,400 rx=70 ry=25\ncard forbidden title=\"Wrong\"\ntext \"Not a screen mark\"\n")
    director.finishCurrentStream()
    await pause(0.4)
    expect(spoken == ["Here is the name."], "annotation uses the narration callback")
    expect(director.annotationScene.overlayModel.items.map(\.id) == ["name"], "annotation draws on its own layer")
    expect(director.annotationScene.cards.isEmpty && director.annotationScene.modelWindow == nil, "annotation rejects generated content surfaces")
    expect(director.scene.modelWindow === model && director.scene.cards.first === card, "annotation preserves existing model and card identities")
    expect(director.scene.log == savedLog, "annotation leaves the existing drawing log untouched")
    expect(director.lastSavedEntryID == "saved-fixture" && director.lastSummary == savedSummary, "annotation preserves the saved drawing and follow-up summary")
    expect(director.scene.narration == savedAudio, "annotation narration does not enter the drawing audio")
    await pause(1)
    expect(director.annotationScene.overlayModel.items.first?.fadeStart == nil, "short spoken annotations remain visible for reading")
    // A control command is scoped to the disposable annotation session too.
    director.annotationScene.feed(chunk: "clear\n")
    director.annotationScene.end()
    await pause(0.1)
    expect(director.scene.modelWindow === model && director.scene.cards.first === card, "annotation clear cannot remove the content being circled")

    // Hold an old speech callback open across replacement; its completion must not reveal
    // queued old marks or end the new turn's annotation layer.
    var resumeOldSpeech: CheckedContinuation<Void, Never>?
    director.speak = { _ in await withCheckedContinuation { resumeOldSpeech = $0 } }
    director.beginAnnotation(question: "Old mark", displayFrame: display)
    director.annotationScene.feed(chunk: "say 1 \"Old voice.\"\nring old at=100,100 r=20\nsay 2 \"Queued voice.\"\nring queued at=200,200 r=20\n")
    director.finishCurrentStream()
    await pause(0.1)
    expect(resumeOldSpeech != nil, "old speech is pending")
    director.speak = { _ in }
    director.beginAnnotation(question: "New mark", displayFrame: display)
    director.annotationScene.feed(chunk: "say 1 \"New voice.\"\nring fresh at=700,600 r=30\n")
    director.finishCurrentStream()
    resumeOldSpeech?.resume()
    await pause(0.4)
    expect(director.annotationScene.overlayModel.items.map(\.id) == ["fresh"], "stale speech cannot reveal old marks into a replacement annotation")
    director.stop()
    expect(director.annotationScene.overlayModel.items.isEmpty, "stop immediately clears annotations")
    expect(director.scene.modelWindow === model && director.scene.cards.first === card, "stop retains content windows")
    let audioAfterStop = director.scene.narration
    director.appendNarrationAudio(Data([0, 1, 0, 1]), sampleRate: 24000)
    expect(director.scene.narration == audioAfterStop, "late stopped annotation audio cannot pollute the retained drawing")
    await pause(3.3)
    expect(director.annotationScene.overlayModel.items.isEmpty, "cancelled reveal and fade callbacks do not resurrect annotations")
    expect(director.scene.log == savedLog && director.lastSavedEntryID == "saved-fixture", "drawing state survives cancellation and delayed callbacks")
    expect(SceneHistory.shared.entries.count == historyCount, "annotations are never saved as drawings")
    director.clear()
    expect(director.scene.modelWindow == nil && director.scene.cards.isEmpty && director.annotationScene.overlayModel.items.isEmpty, "clear removes both content and annotations")
    try? FileManager.default.removeItem(at: testRoot)
    print("\(checks) checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
DispatchQueue.main.async { Task { @MainActor in await run() } }
app.run()
