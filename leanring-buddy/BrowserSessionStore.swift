//
//  BrowserSessionStore.swift
//  Unified access to the user's browser cookies for authenticated agent requests.
//

import Foundation

enum AgentBrowserChoice: String, CaseIterable, Identifiable {
    case auto
    case chrome
    case brave
    case arc
    case edge
    case safari

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Edge"
        case .safari: return "Safari"
        }
    }

    init(toolArgument: String?) {
        guard let toolArgument,
              let parsed = AgentBrowserChoice(rawValue: toolArgument.lowercased()) else {
            self = .auto
            return
        }
        self = parsed
    }
}

struct BrowserSessionSummary: Equatable {
    let browserName: String
    let cookieCount: Int
    let sampleDomains: [String]
}

enum BrowserSessionStore {

    static func installedBrowserNames() -> [String] {
        var names = ChromiumBrowserCookieReader.installedBrowsers().map(\.displayName)
        if SafariBinaryCookiesReader.isSafariInstalled {
            names.append("Safari")
        }
        return names
    }

    static func cookies(for url: URL, browser: AgentBrowserChoice = .auto) throws -> [BrowserCookie] {
        // Off unless the person turned on "browser sign-ins" in Privacy settings.
        guard TeachySettingsStorage.allowBrowserCookieTools() else { return [] }
        guard let host = url.host?.lowercased() else { return [] }

        switch browser {
        case .auto:
            return try cookiesFromAllInstalledBrowsers(matchingHost: host)
        case .safari:
            return try SafariBinaryCookiesReader.cookies(matchingHost: host)
        case .chrome:
            return try ChromiumBrowserCookieReader.cookies(matchingHost: host, browser: .chrome)
        case .brave:
            return try ChromiumBrowserCookieReader.cookies(matchingHost: host, browser: .brave)
        case .arc:
            return try ChromiumBrowserCookieReader.cookies(matchingHost: host, browser: .arc)
        case .edge:
            return try ChromiumBrowserCookieReader.cookies(matchingHost: host, browser: .edge)
        }
    }

    static func cookieHeaderValue(for url: URL, browser: AgentBrowserChoice = .auto) throws -> String? {
        let matchingCookies = try cookies(for: url, browser: browser)
        guard !matchingCookies.isEmpty else { return nil }

        let requestHost = url.host?.lowercased() ?? ""
        let applicableCookies = matchingCookies.filter { cookie in
            cookieAppliesToRequest(cookie: cookie, requestHost: requestHost, requestPath: url.path)
        }

        guard !applicableCookies.isEmpty else { return nil }

        return applicableCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    static func summarizeLoggedInSites(browser: AgentBrowserChoice = .auto) -> [BrowserSessionSummary] {
        var summaries: [BrowserSessionSummary] = []

        for chromiumBrowser in chromiumBrowsersForChoice(browser) {
            if let summary = summarizeChromiumBrowser(chromiumBrowser) {
                summaries.append(summary)
            }
        }

        if browser == .auto || browser == .safari {
            summaries.append(BrowserSessionSummary(
                browserName: "Safari",
                cookieCount: SafariBinaryCookiesReader.isSafariInstalled ? 1 : 0,
                sampleDomains: SafariBinaryCookiesReader.isSafariInstalled ? ["available"] : []
            ))
        }

        return summaries
    }

    // MARK: - Private

    private static func chromiumBrowsersForChoice(_ browser: AgentBrowserChoice) -> [ChromiumBrowser] {
        switch browser {
        case .auto:
            return ChromiumBrowserCookieReader.installedBrowsers()
        case .chrome:
            return ChromiumBrowser.chrome.isInstalled ? [.chrome] : []
        case .brave:
            return ChromiumBrowser.brave.isInstalled ? [.brave] : []
        case .arc:
            return ChromiumBrowser.arc.isInstalled ? [.arc] : []
        case .edge:
            return ChromiumBrowser.edge.isInstalled ? [.edge] : []
        case .safari:
            return []
        }
    }

    private static func cookiesFromAllInstalledBrowsers(matchingHost host: String) throws -> [BrowserCookie] {
        var collectedCookies: [BrowserCookie] = []

        for chromiumBrowser in ChromiumBrowserCookieReader.installedBrowsers() {
            if let browserCookies = try? ChromiumBrowserCookieReader.cookies(matchingHost: host, browser: chromiumBrowser) {
                collectedCookies.append(contentsOf: browserCookies)
            }
        }

        if let safariCookies = try? SafariBinaryCookiesReader.cookies(matchingHost: host) {
            collectedCookies.append(contentsOf: safariCookies)
        }

        return deduplicateCookies(collectedCookies)
    }

    private static func cookieAppliesToRequest(cookie: BrowserCookie, requestHost: String, requestPath: String) -> Bool {
        let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedRequestHost = requestHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let domainMatches = cookieDomain == normalizedRequestHost
            || normalizedRequestHost.hasSuffix(".\(cookieDomain)")
            || (cookie.domain.hasPrefix(".") && normalizedRequestHost.hasSuffix(cookieDomain))

        guard domainMatches else { return false }
        return requestPath.hasPrefix(cookie.path)
    }

    private static func deduplicateCookies(_ cookies: [BrowserCookie]) -> [BrowserCookie] {
        var seenKeys = Set<String>()
        var uniqueCookies: [BrowserCookie] = []
        for cookie in cookies {
            let key = "\(cookie.browserName)|\(cookie.domain)|\(cookie.name)|\(cookie.path)"
            if seenKeys.insert(key).inserted {
                uniqueCookies.append(cookie)
            }
        }
        return uniqueCookies
    }

    private static func summarizeChromiumBrowser(_ browser: ChromiumBrowser) -> BrowserSessionSummary? {
        guard browser.isInstalled else { return nil }

        do {
            let userDataDirectory = browser.applicationSupportDirectoryURL
            var profileDirectories: [URL] = []
            let defaultProfile = userDataDirectory.appendingPathComponent("Default", isDirectory: true)
            if FileManager.default.fileExists(atPath: defaultProfile.path) {
                profileDirectories.append(defaultProfile)
            }
            let profileNames = try FileManager.default.contentsOfDirectory(atPath: userDataDirectory.path)
            for profileName in profileNames where profileName.hasPrefix("Profile ") {
                profileDirectories.append(userDataDirectory.appendingPathComponent(profileName, isDirectory: true))
            }

            var domains = Set<String>()
            var cookieCount = 0

            for profileDirectory in profileDirectories {
                let cookieDatabaseURL = profileDirectory.appendingPathComponent("Cookies")
                guard FileManager.default.fileExists(atPath: cookieDatabaseURL.path) else { continue }

                let temporaryDatabaseURL = try copyCookieDatabaseToTemporaryLocation(cookieDatabaseURL: cookieDatabaseURL)
                defer { try? FileManager.default.removeItem(at: temporaryDatabaseURL) }

                let summary = ChromiumBrowserCookieReader.readDomainSummary(databaseURL: temporaryDatabaseURL)
                cookieCount += summary.cookieCount
                domains.formUnion(summary.domains)
            }

            return BrowserSessionSummary(
                browserName: browser.displayName,
                cookieCount: cookieCount,
                sampleDomains: Array(domains.prefix(12)).sorted()
            )
        } catch {
            return BrowserSessionSummary(browserName: browser.displayName, cookieCount: 0, sampleDomains: [])
        }
    }

    private static func copyCookieDatabaseToTemporaryLocation(cookieDatabaseURL: URL) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-browser-cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let destinationURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: cookieDatabaseURL, to: destinationURL)
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: cookieDatabaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try? FileManager.default.copyItem(at: sidecarURL, to: URL(fileURLWithPath: destinationURL.path + suffix))
            }
        }
        return destinationURL
    }
}
