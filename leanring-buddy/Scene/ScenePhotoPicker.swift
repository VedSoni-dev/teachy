//
//  ScenePhotoPicker.swift
//  leanring-buddy / Scene
//
//  The pure half of finding a photo for a card: reading search and Wikipedia
//  responses, choosing a picture, and deciding whether a download is acceptable.
//  ScenePhotoFetcher does the network and the disk cache.
//
//  Pure (Foundation only).
//

import Foundation

struct ScenePhotoCandidate: Equatable {
    var imageURL: URL
    /// A smaller copy to try when `imageURL` is refused.
    var fallbackImageURL: URL?
    var sourceURL: URL?
    var sourceName: String?
}

enum ScenePhotoPicker {
    static let imageKeys = ["image", "image_url", "imageUrl", "thumbnail", "thumbnail_url", "thumbnailUrl", "img", "og_image"]

    /// An image named by a search result itself, if the search service returns one.
    static func imageInSearchResults(_ results: [[String: Any]]) -> ScenePhotoCandidate? {
        for result in results {
            for key in imageKeys {
                var text = result[key] as? String
                if text == nil, let nested = result[key] as? [String: Any] { text = (nested["url"] ?? nested["src"] ?? nested["source"]) as? String }
                guard let text, let url = URL(string: text), isWebURL(url) else { continue }
                let page = (result["url"] as? String).flatMap(URL.init(string:))
                return ScenePhotoCandidate(imageURL: url, sourceURL: page, sourceName: (result["site"] as? String) ?? page?.host)
            }
        }
        return nil
    }

    /// The article title of the first Wikipedia page among search results ("General_Electric_GE9X").
    static func wikipediaTitle(inSearchResults results: [[String: Any]]) -> String? {
        for result in results {
            guard let text = result["url"] as? String, let title = wikipediaTitle(fromPage: text) else { continue }
            return title
        }
        return nil
    }

    static func wikipediaTitle(fromPage text: String) -> String? {
        guard let url = URL(string: text), let host = url.host?.lowercased(), host == "en.wikipedia.org" || host == "en.m.wikipedia.org",
              url.path.hasPrefix("/wiki/") else { return nil }
        let title = String(url.path.dropFirst("/wiki/".count))
        // Not an article: "File:", "Category:", "Special:"…
        guard !title.isEmpty, !title.contains(":") else { return nil }
        return title.removingPercentEncoding ?? title
    }

    /// The summary endpoint for an article title or a plain phrase.
    static func summaryURL(forTitle title: String) -> URL? {
        let underscored = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard !underscored.isEmpty, let encoded = underscored.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    static func titleSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "4")]
        return components?.url
    }

    /// The lead photo in a page-summary response. Disambiguation pages are refused.
    static func candidate(fromSummary data: Data, width: Int = 960) -> ScenePhotoCandidate? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (json["type"] as? String) == "disambiguation" { return nil }
        let thumbnail = json["thumbnail"] as? [String: Any], original = json["originalimage"] as? [String: Any]
        guard let source = (thumbnail?["source"] ?? original?["source"]) as? String else { return nil }
        let originalWidth = (original?["width"] as? Int) ?? 0
        guard let url = URL(string: resized(thumbnail: source, to: width, originalWidth: originalWidth)), isWebURL(url) else { return nil }
        let page = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        let plain = URL(string: source)
        return ScenePhotoCandidate(imageURL: url, fallbackImageURL: plain == url ? nil : plain, sourceURL: page.flatMap(URL.init(string:)), sourceName: "Wikipedia")
    }

    /// Article keys from Wikipedia's title search, best first, preferring ones that have a picture.
    static func titles(fromTitleSearch data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let pages = json["pages"] as? [[String: Any]] else { return [] }
        let withPicture = pages.filter { $0["thumbnail"] is [String: Any] }.compactMap { $0["key"] as? String }
        let rest = pages.filter { !($0["thumbnail"] is [String: Any]) }.compactMap { $0["key"] as? String }
        return withPicture + rest
    }

    /// The widths Wikimedia serves thumbnails at. Any other width is refused (HTTP 400, seen 14 Nov 2026).
    static let thumbnailSteps = [120, 250, 330, 500, 960, 1280, 1920]

    /// Wikipedia thumbnails are addressed by width (".../330px-Name.jpg"). Ask for the step that
    /// fills a card at 2x: the largest allowed width up to `width`, never wider than the
    /// original and never smaller than the thumbnail we were given.
    static func resized(thumbnail: String, to width: Int, originalWidth: Int) -> String {
        guard let range = thumbnail.range(of: #"/\d+px-"#, options: .regularExpression) else { return thumbnail }
        let current = Int(thumbnail[range].dropFirst().dropLast(3)) ?? 0
        let ceiling = originalWidth > 0 ? min(width, originalWidth) : width
        guard let wanted = thumbnailSteps.last(where: { $0 <= ceiling }), wanted > current else { return thumbnail }
        return thumbnail.replacingCharacters(in: range, with: "/\(wanted)px-")
    }

    static let allowedTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]
    static let maximumBytes = 6_000_000

    /// Whether a download is a picture we are willing to show.
    static func accepts(contentType: String?, byteCount: Int) -> Bool {
        guard byteCount > 200, byteCount <= maximumBytes else { return false }
        guard let type = contentType?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return false }
        return allowedTypes.contains(type)
    }

    static func isWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    /// A file name for a query: the same query (ignoring case and extra spaces) always gives the same name.
    static func cacheKey(for query: String) -> String {
        let normal = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        return String(SceneRNG.hash(normal), radix: 16)
    }
}

