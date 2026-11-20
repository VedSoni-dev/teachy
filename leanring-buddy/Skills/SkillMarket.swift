//
//  SkillMarket.swift
//  leanring-buddy / Skills
//
//  The Skill Market: skills other people wrote, listed on the Teachy site at
//  /skillmarket (academy/skillmarket/ in this repo). The site publishes
//  `index.json`; each listing points at a skill file in the same format as the
//  bundled ones (SkillLibrary.swift), with `id`, `version` and `author` added to
//  the front matter. Installing a skill writes it to `~/.teachy/skills/<id>.md`,
//  where SkillLibrary already picks it up.
//
//  Everything here is pure (Foundation only, no network, folder passed in) so
//  scripts/tests/run_skill_market_tests.sh can test it against a temp folder.
//  The network and UI state live in SkillStore.swift.
//

import Foundation

nonisolated enum SkillMarketConfiguration {
    /// The market page people browse in a web browser.
    static let pageURL = URL(string: "https://vedsoni-dev.github.io/teachy/skillmarket/")!
    /// The machine-readable list the app reads. Built by scripts/build-skillmarket.mjs.
    static let indexURL = URL(string: "https://vedsoni-dev.github.io/teachy/skillmarket/index.json")!
    /// How to publish a skill (a pull request that adds one file).
    static let submitURL = URL(string: "https://github.com/VedSoni-dev/teachy/blob/main/academy/skillmarket/README.md")!
    /// The download counter (skillmarket-worker/): `GET /counts`, `POST /count`.
    static let countsBaseURL = URL(string: "https://teachy-skillmarket.vedantn06soni.workers.dev/")!
    /// Skills are short notes. Anything bigger is not a skill and would crowd the prompt.
    static let maximumSkillFileBytes = 32 * 1024
}

/// One entry in the market's `index.json`.
nonisolated struct SkillMarketListing: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var author: String
    var authorURL: String?
    var category: String?
    /// The app or site names shown on the card, for example ["Linear", "linear.app"].
    var apps: [String]?
    var version: String
    /// The skill file, absolute or relative to `index.json`.
    var file: String
    /// Library presentation, copied from the file's front matter by the build script.
    var icon: String? = nil
    var headline: String? = nil
    var description: String? = nil
    var goodFor: [String]? = nil
    var highlights: [String]? = nil
    /// `YYYY-MM-DD`; listings added in the last 30 days show a New badge.
    var added: String? = nil

    func isNew(now: Date = Date()) -> Bool {
        guard let added else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let addedDate = formatter.date(from: added) else { return false }
        let age = now.timeIntervalSince(addedDate)
        return age >= 0 && age < 30 * 24 * 60 * 60
    }
}

nonisolated struct SkillMarketIndex: Codable, Equatable, Sendable {
    var version: Int
    var skills: [SkillMarketListing]

    /// Decodes `index.json` and drops listings with an unusable ID or file. Nil when it is not an index at all.
    static func decode(_ data: Data) -> SkillMarketIndex? {
        guard var index = try? JSONDecoder().decode(SkillMarketIndex.self, from: data) else { return nil }
        index.skills = index.skills.filter { SkillMarketRules.isValidID($0.id) && !$0.file.isEmpty && !$0.name.isEmpty }
        return index
    }
}

nonisolated enum SkillMarketRules {
    /// Lowercase letters, digits and single hyphens, 1–64 characters. Used as the file name, so nothing else.
    static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.count), !id.hasPrefix("-"), !id.hasSuffix("-"), !id.contains("--") else { return false }
        return id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// `"Google Sheets (mine)"` → `"google-sheets-mine"`. Empty when nothing usable is left.
    static func slug(from name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if ("a"..."z").contains(character) || ("0"..."9").contains(character) {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Where a listing's file lives. Only https (or a file next to a local test index) is accepted.
    static func fileURL(for listing: SkillMarketListing, indexURL: URL) -> URL? {
        guard let url = URL(string: listing.file, relativeTo: indexURL)?.absoluteURL else { return nil }
        let scheme = url.scheme?.lowercased()
        if scheme == "https" { return url }
        if scheme == "file", indexURL.isFileURL { return url }
        return nil
    }

    /// Compares dotted versions number by number ("1.10" is newer than "1.9"). Non-numbers compare as text.
    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map(String.init)
        let installedParts = installed.split(separator: ".").map(String.init)
        for position in 0..<max(candidateParts.count, installedParts.count) {
            let candidatePart = position < candidateParts.count ? candidateParts[position] : "0"
            let installedPart = position < installedParts.count ? installedParts[position] : "0"
            if let candidateNumber = Int(candidatePart), let installedNumber = Int(installedPart) {
                if candidateNumber != installedNumber { return candidateNumber > installedNumber }
            } else if candidatePart != installedPart {
                return candidatePart > installedPart
            }
        }
        return false
    }
}

/// How a listing relates to what is on this Mac.
nonisolated enum SkillMarketInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case updateAvailable(installedVersion: String)

    static func of(_ listing: SkillMarketListing, userSkills: [Skill]) -> SkillMarketInstallState {
        guard let installed = userSkills.first(where: { $0.marketID == listing.id }) else { return .notInstalled }
        let installedVersion = installed.version ?? "0"
        return SkillMarketRules.isVersion(listing.version, newerThan: installedVersion)
            ? .updateAvailable(installedVersion: installedVersion) : .installed
    }
}

/// A skill file checked and ready to be written. Made only by `SkillInstaller.validate`.
nonisolated struct ValidatedSkillFile: Equatable, Sendable {
    var skill: Skill
    var text: String
    /// The file name it will be saved under, without the folder.
    var fileName: String
}

nonisolated enum SkillInstallError: LocalizedError, Equatable {
    case tooLarge
    case notText
    case notASkill
    case noMatchingApp
    case wrongListing(expected: String, found: String)
    case couldNotSave(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "That file is too big to be a skill (the limit is 32 KB)."
        case .notText: return "That file isn't plain text."
        case .notASkill: return "That isn't a Teachy skill. A skill file starts with a --- block that has at least a name."
        case .noMatchingApp: return "The skill doesn't say which app or site it's for. Add bundleIds or sites to its front matter."
        case .wrongListing(let expected, let found): return "The file is for \"\(found)\", not the listing \"\(expected)\"."
        case .couldNotSave(let reason): return "Couldn't save the skill: \(reason)"
        }
    }
}

nonisolated enum SkillInstaller {
    /// Checks a downloaded or chosen file. `expectedMarketID` is the listing it was downloaded for, if any;
    /// the file must carry that ID so one listing cannot overwrite another skill.
    static func validate(data: Data, expectedMarketID: String? = nil, existingFileNames: Set<String> = []) -> Result<ValidatedSkillFile, SkillInstallError> {
        guard data.count <= SkillMarketConfiguration.maximumSkillFileBytes else { return .failure(.tooLarge) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return .failure(.notText) }
        guard let skill = SkillParser.parse(text, origin: "user") else { return .failure(.notASkill) }
        guard !skill.bundleIDs.isEmpty || !skill.sites.isEmpty else { return .failure(.noMatchingApp) }

        if let expectedMarketID {
            guard skill.marketID == expectedMarketID else {
                return .failure(.wrongListing(expected: expectedMarketID, found: skill.marketID ?? skill.name))
            }
            return .success(ValidatedSkillFile(skill: skill, text: text, fileName: expectedMarketID + ".md"))
        }

        // A file from the market (with a valid id) keeps its ID name, so a later update replaces it.
        if let marketID = skill.marketID, SkillMarketRules.isValidID(marketID) {
            return .success(ValidatedSkillFile(skill: skill, text: text, fileName: marketID + ".md"))
        }
        // A person's own file: named after the skill, never on top of a different file.
        let base = SkillMarketRules.slug(from: skill.name).isEmpty ? "skill" : SkillMarketRules.slug(from: skill.name)
        var fileName = base + ".md"
        var counter = 2
        while existingFileNames.contains(fileName) {
            fileName = "\(base)-\(counter).md"
            counter += 1
        }
        return .success(ValidatedSkillFile(skill: skill, text: text, fileName: fileName))
    }

    /// Writes the file into `directory` (made if missing), replacing a file of the same name. Returns where it went.
    @discardableResult
    static func install(_ file: ValidatedSkillFile, into directory: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(file.fileName)
            try Data(file.text.utf8).write(to: destination, options: .atomic)
            return destination
        } catch {
            throw SkillInstallError.couldNotSave(error.localizedDescription)
        }
    }

    /// Moves a user skill file to the Trash (so a mistaken remove can be undone in Finder).
    /// Refuses anything outside `directory`, so a bundled skill can never be removed.
    static func remove(fileURL: URL, from directory: URL) throws {
        let folder = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let target = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard target.deletingLastPathComponent().path == folder else {
            throw SkillInstallError.couldNotSave("that skill isn't in your skills folder")
        }
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// The file names already in the folder, for choosing a name that doesn't clash.
    static func existingFileNames(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.resolvingSymlinksInPath().path)) ?? []
        return Set(names)
    }

    /// A starting point for a new skill of the person's own.
    static let newSkillTemplate = """
    ---
    name: My App
    bundleIds: [com.example.MyApp]
    sites: []
    summary: One line on what the app is.
    ---
    ## Layout
    - Where the main areas are, by the names shown on screen.

    ## Where things are
    - The things people ask for most, and how to get to each.

    ## Gotchas
    - What trips people up.

    ## Shortcuts
    - The keys worth knowing.

    """
}

/// `teachy://skill?url=https://…` (the market's "Get" button). Returns the skill file URL, or nil
/// when the link is not a skill link or the file isn't https.
nonisolated enum SkillInstallLink {
    static func skillFileURL(from link: URL) -> URL? {
        guard link.scheme?.lowercased() == "teachy", link.host?.lowercased() == "skill" else { return nil }
        guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}

/// The counter's `GET /counts` answer: `{ "counts": { "<listing id>": <downloads> } }`.
nonisolated enum SkillDownloadCounts {
    static func decode(_ data: Data) -> [String: Int]? {
        struct Answer: Decodable { var counts: [String: Int] }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.counts
    }

    /// "1 download", "1,204 downloads", "No downloads yet".
    static func label(for count: Int?) -> String? {
        guard let count else { return nil }
        if count <= 0 { return "No downloads yet" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        let number = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return count == 1 ? "1 download" : "\(number) downloads"
    }
}
