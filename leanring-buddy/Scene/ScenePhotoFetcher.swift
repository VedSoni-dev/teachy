//
//  ScenePhotoFetcher.swift
//  leanring-buddy / Scene
//
//  Finds a real photo for a card's `image query="…"` line.
//
//    1. The disk cache (~/Library/Caches/…/scene-photos), keyed by the query.
//    2. A web search the host supplies (publik `POST /search`). If a result carries an
//       image or thumbnail URL, that is used. As of 14 Nov 2026 publik's results have
//       only title, url, site, snippet and age, so in practice this step only tells us
//       which Wikipedia article the query is about.
//    3. Wikipedia's page summary for that article (or for the query itself), which has a
//       lead photo. Free, no key.
//    4. Wikipedia's own title search, when nothing above named an article.
//
//  The photo is downloaded with a size and type limit and saved beside a small
//  JSON note of the page it came from, so the card can show a "source" link.
//  Everything here runs off the drawing's path: a card never waits for its photo.
//
//  ScenePhotoPicker (ScenePhotoPicker.swift) is the pure half: parsing and choosing, checked by tests.
//

import AppKit
import Foundation

// MARK: - Fetching

@MainActor
final class ScenePhotoFetcher {
    /// Web search results for a query: dictionaries with at least "url", as publik's `/search` returns.
    typealias Search = (String) async -> [[String: Any]]

    private let cacheFolder: URL
    private let search: Search?
    private let session: URLSession
    private var inFlight: [String: Task<ScenePhoto?, Never>] = [:]
    private var misses: Set<String> = []

    /// `cacheFolder` nil means ~/Library/Caches/<bundle id>/scene-photos.
    init(cacheFolder: URL? = nil, search: Search? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheFolder = cacheFolder ?? caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.teachy.app", isDirectory: true)
            .appendingPathComponent("scene-photos", isDirectory: true)
        self.search = search
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = ["User-Agent": "TeachyApp/1.0 (macOS; scene photos)"]
        session = URLSession(configuration: configuration)
    }

    /// A photo for `query`, from the cache when it has been asked for before. Nil when none can be found.
    func photo(for query: String) async -> ScenePhoto? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = ScenePhotoPicker.cacheKey(for: trimmed)
        if let cached = cachedPhoto(key: key) { return cached }
        if misses.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }
        let task = Task<ScenePhoto?, Never> { [weak self] in await self?.find(trimmed, key: key) }
        inFlight[key] = task
        let photo = await task.value
        inFlight[key] = nil
        if photo == nil { misses.insert(key) }
        return photo
    }

    private func find(_ query: String, key: String) async -> ScenePhoto? {
        var candidates: [ScenePhotoCandidate] = []
        var titles: [String] = []
        if let search {
            let results = await search(query)
            if let direct = ScenePhotoPicker.imageInSearchResults(results) { candidates.append(direct) }
            if let title = ScenePhotoPicker.wikipediaTitle(inSearchResults: results) { titles.append(title) }
        }
        titles.append(query)
        for candidate in candidates {
            if let photo = await download(candidate, query: query, key: key) { return photo }
        }
        for title in titles {
            if let candidate = await summaryCandidate(title: title), let photo = await download(candidate, query: query, key: key) { return photo }
        }
        // Nothing named an article: ask Wikipedia which article the phrase means.
        if let url = ScenePhotoPicker.titleSearchURL(for: query), let data = await get(url, limit: 400_000) {
            for title in ScenePhotoPicker.titles(fromTitleSearch: data).prefix(2) where !titles.contains(title) {
                if let candidate = await summaryCandidate(title: title), let photo = await download(candidate, query: query, key: key) { return photo }
            }
        }
        return nil
    }

    private func summaryCandidate(title: String) async -> ScenePhotoCandidate? {
        guard let url = ScenePhotoPicker.summaryURL(forTitle: title), let data = await get(url, limit: 400_000) else { return nil }
        return ScenePhotoPicker.candidate(fromSummary: data)
    }

    private func get(_ url: URL, limit: Int) async -> Data? {
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit else { return nil }
        return data
    }

    private func download(_ candidate: ScenePhotoCandidate, query: String, key: String) async -> ScenePhoto? {
        if let photo = await download(from: candidate.imageURL, candidate: candidate, query: query, key: key) { return photo }
        guard let fallback = candidate.fallbackImageURL else { return nil }
        return await download(from: fallback, candidate: candidate, query: query, key: key)
    }

    private func download(from imageURL: URL, candidate: ScenePhotoCandidate, query: String, key: String) async -> ScenePhoto? {
        guard ScenePhotoPicker.isWebURL(imageURL) else { return nil }
        var request = URLRequest(url: imageURL)
        request.setValue("image/jpeg,image/png,image/webp,image/gif", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")
        // Refuse early on a declared size, and stop reading the moment the limit is passed.
        if http.expectedContentLength > Int64(ScenePhotoPicker.maximumBytes) { return nil }
        var data = Data()
        data.reserveCapacity(max(Int(http.expectedContentLength), 0))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > ScenePhotoPicker.maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        guard ScenePhotoPicker.accepts(contentType: type, byteCount: data.count), let image = NSImage(data: data), image.size.width > 8, image.size.height > 8 else { return nil }
        store(data, imageURL: imageURL, candidate: candidate, query: query, key: key)
        return ScenePhoto(image: image, sourceURL: candidate.sourceURL, sourceName: candidate.sourceName)
    }

    // MARK: Cache

    private func cachedPhoto(key: String) -> ScenePhoto? {
        let imageFile = cacheFolder.appendingPathComponent("\(key).img"), noteFile = cacheFolder.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: imageFile), let image = NSImage(data: data) else { return nil }
        let note = (try? Data(contentsOf: noteFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ScenePhoto(image: image, sourceURL: (note?["source"] as? String).flatMap(URL.init(string:)), sourceName: note?["sourceName"] as? String)
    }

    private func store(_ data: Data, imageURL: URL, candidate: ScenePhotoCandidate, query: String, key: String) {
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try? data.write(to: cacheFolder.appendingPathComponent("\(key).img"), options: .atomic)
        var note: [String: Any] = ["query": query, "image": imageURL.absoluteString, "fetched": ISO8601DateFormatter().string(from: Date())]
        if let source = candidate.sourceURL { note["source"] = source.absoluteString }
        if let name = candidate.sourceName { note["sourceName"] = name }
        if let encoded = try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys]) {
            try? encoded.write(to: cacheFolder.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }
}
