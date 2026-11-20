//
//  SkillStore.swift
//  leanring-buddy / Skills
//
//  UI state for Settings → Skills: the skills on this Mac, the Skill Market
//  listings, and installs (from the market, from a file, or from a
//  `teachy://skill?url=` link on the market page). Every install from outside
//  the market list is shown to the person first (`pendingInstall`) and only
//  written once they confirm, because a skill's text goes into what Teachy reads.
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    enum MarketLoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    /// A skill fetched or chosen, waiting for the person to confirm.
    struct PendingInstall: Identifiable, Equatable {
        let id = UUID()
        var file: ValidatedSkillFile
        /// "skillmarket", a host name, or "a file on this Mac".
        var sourceDescription: String
        /// The bundled skill it would replace, if any.
        var replacesBuiltInSkillNamed: String?
    }

    @Published private(set) var userSkills: [Skill] = []
    @Published private(set) var bundledSkills: [Skill] = []
    @Published private(set) var listings: [SkillMarketListing] = []
    @Published private(set) var marketLoadState: MarketLoadState = .idle
    /// Listing IDs being downloaded right now.
    @Published private(set) var installingListingIDs: Set<String> = []
    @Published var pendingInstall: PendingInstall?
    /// Downloads per listing ID from the counter; nil until it answers (or when it can't be reached).
    /// Settable so the off-screen renders can show counts without a network.
    @Published var downloadCounts: [String: Int]?
    /// The last thing that went wrong, shown under the section it came from.
    @Published var lastError: String?

    private let library: SkillLibrary
    private let userDirectory: URL
    private let indexURL: URL
    private let session: URLSession

    init(library: SkillLibrary = .shared,
         userDirectory: URL = SkillLibrary.userDirectory,
         indexURL: URL = SkillMarketConfiguration.indexURL,
         session: URLSession = .shared) {
        self.library = library
        self.userDirectory = userDirectory
        self.indexURL = indexURL
        self.session = session
        refreshInstalledSkills()
    }

    // MARK: Installed

    func refreshInstalledSkills() {
        library.reload()
        userSkills = library.userSkills
        bundledSkills = library.bundledSkills
    }

    func installState(of listing: SkillMarketListing) -> SkillMarketInstallState {
        SkillMarketInstallState.of(listing, userSkills: userSkills)
    }

    func remove(_ skill: Skill) {
        guard let fileURL = skill.fileURL else { return }
        do {
            try SkillInstaller.remove(fileURL: fileURL, from: userDirectory)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshInstalledSkills()
    }

    func revealInFinder(_ skill: Skill) {
        guard let fileURL = skill.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openInEditor(_ skill: Skill) {
        guard let fileURL = skill.fileURL else { return }
        NSWorkspace.shared.open(fileURL)
    }

    func openSkillsFolder() {
        try? FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userDirectory)
    }

    /// Writes the starter template under a free name and opens it in the person's text editor.
    func createNewSkill() {
        let existing = SkillInstaller.existingFileNames(in: userDirectory)
        var fileName = "my-skill.md"
        var counter = 2
        while existing.contains(fileName) {
            fileName = "my-skill-\(counter).md"
            counter += 1
        }
        do {
            try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            let destination = userDirectory.appendingPathComponent(fileName)
            try Data(SkillInstaller.newSkillTemplate.utf8).write(to: destination, options: .withoutOverwriting)
            NSWorkspace.shared.open(destination)
            lastError = nil
        } catch {
            lastError = "Couldn't create the skill file: \(error.localizedDescription)"
        }
        refreshInstalledSkills()
    }

    /// Asks for a Markdown file and stages it for confirmation.
    func chooseFileToAdd() {
        let panel = NSOpenPanel()
        panel.title = "Add a skill"
        panel.message = "Choose a Teachy skill file (.md)."
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // The settings panel never becomes key; float the open panel above it.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The library shows the staged skill with its full detail and the Add button.
        SkillsLibraryWindowController.shared.show()
        stageLocalFile(url)
    }

    func stageLocalFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Couldn't read that file."
            return
        }
        stage(data: data, expectedMarketID: nil, sourceDescription: "a file on this Mac")
    }

    // MARK: Market

    func loadMarketIfNeeded() async {
        if marketLoadState == .loading || marketLoadState == .loaded { return }
        await loadMarket()
    }

    func loadMarket() async {
        marketLoadState = .loading
        do {
            var request = URLRequest(url: indexURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                marketLoadState = .failed("The Skill Market answered with error \(http.statusCode).")
                return
            }
            guard let index = SkillMarketIndex.decode(data) else {
                marketLoadState = .failed("The Skill Market list couldn't be read.")
                return
            }
            listings = index.skills
            marketLoadState = .loaded
            await loadDownloadCounts()
        } catch {
            marketLoadState = .failed("Couldn't reach the Skill Market. Check your connection.")
        }
    }

    /// Counts are a nicety: a failure leaves them out and changes nothing else.
    func loadDownloadCounts() async {
        // Only the real market has a counter; a local test index has none.
        guard indexURL == SkillMarketConfiguration.indexURL else { return }
        let url = SkillMarketConfiguration.countsBaseURL.appendingPathComponent("counts")
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let counts = SkillDownloadCounts.decode(data) else { return }
        downloadCounts = counts
    }

    /// Adds one to a listing's downloads. Sends only the listing ID; the counter keeps no
    /// record of who sent it (see skillmarket-worker/README.md). Updates are not counted.
    private func reportDownload(of listingID: String) {
        guard indexURL == SkillMarketConfiguration.indexURL else { return }
        if downloadCounts != nil { downloadCounts?[listingID, default: 0] += 1 }
        var request = URLRequest(url: SkillMarketConfiguration.countsBaseURL.appendingPathComponent("count"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["id": listingID, "source": "app"])
        let session = self.session
        Task.detached { _ = try? await session.data(for: request) }
    }

    /// Market listings are installed straight away: the person pressed Get on that listing.
    func install(_ listing: SkillMarketListing) async {
        guard let fileURL = SkillMarketRules.fileURL(for: listing, indexURL: indexURL) else {
            lastError = "That listing's file link isn't safe to download."
            return
        }
        installingListingIDs.insert(listing.id)
        defer { installingListingIDs.remove(listing.id) }
        guard let data = await download(fileURL) else { return }
        let wasInstalled = installState(of: listing) != .notInstalled
        switch SkillInstaller.validate(data: data, expectedMarketID: listing.id) {
        case .success(let file):
            write(file)
            if !wasInstalled, lastError == nil { reportDownload(of: listing.id) }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    /// From a `teachy://skill?url=` link: downloads, then waits for the person to confirm.
    func stageInstall(fromLink fileURL: URL) async {
        guard let data = await download(fileURL) else { return }
        let marketHost = SkillMarketConfiguration.indexURL.host
        let source = fileURL.host == marketHost ? "the Skill Market" : (fileURL.host ?? "the web")
        stage(data: data, expectedMarketID: nil, sourceDescription: source)
    }

    func confirmPendingInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        // A market skill added from the website's Add to Teachy counts as a download of that listing.
        let marketID = pending.file.skill.marketID
        let wasInstalled = userSkills.contains { $0.marketID != nil && $0.marketID == marketID }
        write(pending.file)
        if let marketID, !wasInstalled, lastError == nil, listings.contains(where: { $0.id == marketID }) {
            reportDownload(of: marketID)
        }
    }

    func cancelPendingInstall() {
        pendingInstall = nil
    }

    // MARK: Private

    private func stage(data: Data, expectedMarketID: String?, sourceDescription: String) {
        let existing = SkillInstaller.existingFileNames(in: userDirectory)
        switch SkillInstaller.validate(data: data, expectedMarketID: expectedMarketID, existingFileNames: existing) {
        case .success(let file):
            let replaced = bundledSkills.first { $0.name.lowercased() == file.skill.name.lowercased() }?.name
            pendingInstall = PendingInstall(file: file, sourceDescription: sourceDescription, replacesBuiltInSkillNamed: replaced)
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    private func write(_ file: ValidatedSkillFile) {
        do {
            try SkillInstaller.install(file, into: userDirectory)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshInstalledSkills()
    }

    private func download(_ url: URL) async -> Data? {
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "The skill couldn't be downloaded (error \(http.statusCode))."
                return nil
            }
            return data
        } catch {
            lastError = "The skill couldn't be downloaded. Check your connection."
            return nil
        }
    }
}
