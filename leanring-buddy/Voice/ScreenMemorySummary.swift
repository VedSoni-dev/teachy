//
//  ScreenMemorySummary.swift
//  leanring-buddy
//
//  Turns "what is on screen right now" into one short line for the Brain's
//  "Screen memory" section, without asking a model: the app's name, the window
//  title, the page's host and path, and the first couple of hundred characters of
//  text if the caller has some. Also decides when a screen is the same one as last
//  time, so sitting on one page does not fill the memory. Pure, tested.
//

import Foundation

nonisolated struct ScreenSnapshot: Equatable, Sendable {
    var frontApp: String
    var windowTitle: String?
    var browserURL: String?
    /// Visible text, if the caller has it (for example from the accessibility tree).
    var text: String?
}

nonisolated enum ScreenMemorySummary {
    static let maximumTextCharacters = 200
    static let maximumLineCharacters = 360

    /// Apps whose windows are never written down.
    static let privateAppNames: [String] = [
        "1Password", "Keychain Access", "Passwords", "Bitwarden", "LastPass", "Dashlane", "KeePassXC", "Proton Pass", "Enpass",
    ]
    /// Window-title fragments that mean a private window.
    static let privateTitleFragments: [String] = ["private browsing", "incognito", "inprivate", "private window"]

    static func isPrivate(_ snapshot: ScreenSnapshot) -> Bool {
        let app = snapshot.frontApp.lowercased()
        if privateAppNames.contains(where: { app.contains($0.lowercased()) }) { return true }
        let title = (snapshot.windowTitle ?? "").lowercased()
        return privateTitleFragments.contains { title.contains($0) }
    }

    /// "github.com/VedSoni-dev/teachy" from a full address. The query string and
    /// fragment are dropped: they often carry tokens and search terms.
    static func hostAndPath(of urlText: String?) -> String? {
        guard let urlText = urlText?.trimmingCharacters(in: .whitespacesAndNewlines), !urlText.isEmpty,
              let components = URLComponents(string: urlText), let host = components.host, !host.isEmpty
        else { return nil }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.count > 80 { path = String(path.prefix(80)) + "…" }
        return trimmedHost + path
    }

    /// The first URL inside a longer piece of text (such as `Safari tab: "Title" — https://…`).
    static func firstURL(in text: String?) -> String? {
        guard let text, let range = text.range(of: #"https?://[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two snapshots with the same key are the same screen (the text may have scrolled).
    static func dedupeKey(for snapshot: ScreenSnapshot) -> String {
        [
            collapse(snapshot.frontApp).lowercased(),
            collapse(snapshot.windowTitle ?? "").lowercased(),
            (hostAndPath(of: snapshot.browserURL) ?? "").lowercased(),
        ].joined(separator: "|")
    }

    /// One line such as `Safari: "Pull requests" (github.com/VedSoni-dev/teachy/pulls). Open 3, Closed 12…`.
    /// Nil when there is nothing worth writing or the window is private.
    static func line(for snapshot: ScreenSnapshot) -> String? {
        let app = collapse(snapshot.frontApp)
        guard !app.isEmpty, !isPrivate(snapshot) else { return nil }
        let title = collapse(snapshot.windowTitle ?? "")
        let page = hostAndPath(of: snapshot.browserURL)
        // An app with no title and no page says nothing a later question could use.
        guard !title.isEmpty || page != nil else { return nil }

        var line = app
        if !title.isEmpty, title.caseInsensitiveCompare(app) != .orderedSame { line += ": \"\(title)\"" }
        if let page { line += " (\(page))" }
        let text = collapse(snapshot.text ?? "")
        if !text.isEmpty {
            let clipped = text.count > maximumTextCharacters ? String(text.prefix(maximumTextCharacters)) + "…" : text
            line += ". " + clipped
        }
        if line.count > maximumLineCharacters { line = String(line.prefix(maximumLineCharacters)) + "…" }
        return line
    }
}

/// Remembers which screens were written down lately, so the same one is not written
/// twice in a row, and so writing is limited however often it is called.
nonisolated struct ScreenMemoryLog {
    /// The same screen is written again only after this long.
    var repeatAfter: TimeInterval = 30 * 60
    /// At most this many notes in any hour.
    var maximumPerHour = 20

    private var lastKey: String?
    private var lastKeyAt: Date?
    private var recentWrites: [Date] = []

    init() {}

    /// The line to store for this snapshot, or nil to store nothing.
    mutating func lineToRecord(for snapshot: ScreenSnapshot, at now: Date = Date()) -> String? {
        guard let line = ScreenMemorySummary.line(for: snapshot) else { return nil }
        let key = ScreenMemorySummary.dedupeKey(for: snapshot)
        if key == lastKey, let lastKeyAt, now.timeIntervalSince(lastKeyAt) < repeatAfter { return nil }
        recentWrites.removeAll { now.timeIntervalSince($0) >= 3600 }
        guard recentWrites.count < maximumPerHour else { return nil }
        lastKey = key
        lastKeyAt = now
        recentWrites.append(now)
        return line
    }
}
