//
//  ClickyAcademyCatalog.swift
//  leanring-buddy
//
//  Free Teachy Academy — public course registry + install URL helpers.
//  Website: academy/ (retro Facebook-style). Registry JSON lists installable tracks.
//

import Foundation

struct ClickyAcademyRegistry: Codable, Equatable {
    let name: String
    let tagline: String
    let websiteURL: String?
    let courses: [ClickyAcademyRegistryCourse]
}

struct ClickyAcademyRegistryCourse: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let authorName: String
    let authorHandle: String?
    let estimatedMinutes: Int
    let goalCount: Int
    let trackTitle: String?
    let installURL: String
    let hasVideoParts: Bool
    let shipsWithApp: Bool?
    let blurb: String

    var isBundledWithApp: Bool { shipsWithApp == true }
}

enum ClickyAcademyConfiguration {
    static let defaultRegistryURLString =
        "https://raw.githubusercontent.com/VedSoni-dev/teachy/main/academy/registry.json"
    static let defaultWebsiteURLString =
        "https://raw.githack.com/VedSoni-dev/teachy/main/academy/index.html"

    static var registryURLString: String {
        AppBundleConfiguration.stringValue(forKey: "TeachyAcademyRegistryURL")
            ?? AppBundleConfiguration.stringValue(forKey: "ClickyAcademyRegistryURL")
            ?? defaultRegistryURLString
    }

    static var websiteURLString: String {
        AppBundleConfiguration.stringValue(forKey: "TeachyAcademyWebsiteURL")
            ?? AppBundleConfiguration.stringValue(forKey: "ClickyAcademyWebsiteURL")
            ?? defaultWebsiteURLString
    }
}

enum ClickyCourseInstallURLResolver {
    /// Turns GitHub blob links into raw.githubusercontent.com URLs so installs work from browser copy-paste.
    static func resolveJSONDownloadURL(from rawURLString: String) -> URL? {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let githubBlobURL = convertGitHubBlobURLToRaw(trimmed) {
            return githubBlobURL
        }

        return URL(string: trimmed)
    }

    private static func convertGitHubBlobURLToRaw(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        var pathParts = url.path.split(separator: "/").map(String.init)
        guard pathParts.count >= 4, pathParts[2] == "blob" else { return nil }

        let owner = pathParts[0]
        let repo = pathParts[1]
        let ref = pathParts[3]
        let filePath = pathParts.dropFirst(4).joined(separator: "/")
        guard !filePath.isEmpty else { return nil }

        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(filePath)")
    }
}

enum ClickyCourseInstallError: LocalizedError {
    case invalidURL
    case downloadFailed(String)
    case invalidCourseJSON
    case conflictsWithBundledCourse(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn’t look like a course URL."
        case .downloadFailed(let detail):
            return "Couldn’t download the course. \(detail)"
        case .invalidCourseJSON:
            return "That file isn’t a valid Teachy course JSON."
        case .conflictsWithBundledCourse(let courseID):
            return "Course id “\(courseID)” is built into Teachy. Pick a different id for your pack."
        case .writeFailed(let detail):
            return "Couldn’t save the course. \(detail)"
        }
    }
}
