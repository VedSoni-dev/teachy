//
//  SceneHistory.swift
//  leanring-buddy / Scene
//
//  Every finished drawing is kept, so it can be played again or saved as a video.
//
//      ~/.teachy/drawings/<yyyy-MM-dd>-<id>/
//          meta.json        title, the question, when, how long, whether it has a voice track
//          scene.json       the replay log (every command and the moment it was drawn)
//          thumb.png        a small picture of the finished drawing
//          narration.pcm    the voice, mono 16-bit PCM (only when the host captured it)
//          video.mp4        written the first time the drawing is saved as a video
//
//  SceneHistoryStore (SceneHistoryStore.swift) is the plain file half: no AppKit, and the
//  tests run it in a temp folder. SceneHistory is the observable object the UI and the director use.
//

import AppKit
import Combine
import Foundation

enum SceneHistoryError: LocalizedError {
    case missing

    var errorDescription: String? { "That drawing is no longer saved." }
}

@MainActor
final class SceneHistory: ObservableObject {
    static let shared = SceneHistory()

    @Published private(set) var entries: [SceneHistoryEntry] = []
    /// Ids being rendered to video right now, with how far along each is (0–1).
    @Published private(set) var exportProgress: [String: Double] = [:]

    let store: SceneHistoryStore
    /// Plays a saved log on screen. `SceneDirector` sets this.
    var player: ((SceneReplayLog) -> Void)?
    /// Finds photos again for cards in an exported video (they come from the disk cache).
    var photoFetcher: ((String) async -> ScenePhoto?)?

    init(root: URL? = nil) {
        store = SceneHistoryStore(root: root ?? SceneHistoryStore.defaultRoot)
        entries = store.entries()
    }

    func reload() { entries = store.entries() }

    /// Keeps a finished drawing. `thumbnail` is drawn small; nil saves the drawing without a picture.
    @discardableResult
    func save(log: SceneReplayLog, question: String, thumbnail: NSImage?, narration: SceneNarrationAudio = SceneNarrationAudio(), projectID: String? = nil) -> SceneHistoryEntry? {
        let entry = store.save(log: log, question: question, thumbnailPNG: thumbnail.flatMap(Self.png), narration: narration, projectID: projectID)
        if entry != nil { reload() }
        return entry
    }

    /// Saves a later version of a drawing over the one kept under `id` (see `SceneHistoryStore.update`).
    @discardableResult
    func update(id: String, log: SceneReplayLog, thumbnail: NSImage?, narration: SceneNarrationAudio = SceneNarrationAudio()) -> SceneHistoryEntry? {
        let entry = store.update(id: id, log: log, thumbnailPNG: thumbnail.flatMap(Self.png), narration: narration)
        if entry != nil { reload() }
        return entry
    }

    @discardableResult
    func assign(entryID: String, toProjectID projectID: String?) -> Bool {
        guard store.assign(entryID: entryID, toProjectID: projectID) else { return false }
        reload()
        return true
    }

    func thumbnail(for id: String) -> NSImage? {
        NSImage(contentsOf: store.thumbnailURL(for: id))
    }

    /// Plays a saved drawing again on screen, with its original timing.
    func replay(_ id: String) {
        guard let log = store.log(for: id) else { return }
        replayingID = id
        player?(log)
    }

    /// The saved drawing most recently played with `replay(_:)`, so a refinement of it can be saved over it.
    private(set) var replayingID: String?

    /// Renders a saved drawing to `video.mp4` in its folder and returns where it is. A drawing
    /// already rendered is returned at once.
    func export(_ id: String) async throws -> URL {
        guard let entry = entries.first(where: { $0.id == id }) ?? store.entries().first(where: { $0.id == id }), let log = store.log(for: id) else {
            throw SceneHistoryError.missing
        }
        let url = store.videoURL(for: id)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 10_000 { return url }
        exportProgress[id] = 0
        defer { exportProgress[id] = nil }
        let partial = url.deletingLastPathComponent().appendingPathComponent("video-partial.mp4")
        do {
            try await SceneVideoExporter.export(log: log, narration: store.narration(for: entry), to: partial, photoFetcher: photoFetcher) { [weak self] progress in
                self?.exportProgress[id] = progress
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        return url
    }

    func delete(_ id: String) {
        store.delete(id)
        reload()
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
