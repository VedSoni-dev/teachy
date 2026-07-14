//
//  SafariBinaryCookiesReader.swift
//  Reads cookies from Safari's Cookies.binarycookies file.
//

import Foundation

enum SafariBinaryCookiesReader {

    static var isSafariInstalled: Bool {
        FileManager.default.fileExists(atPath: safariCookiesFileURL.path)
    }

    private static var safariCookiesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }

    /// Returns cookies from Safari whose domain matches `host`.
    static func cookies(matchingHost host: String) throws -> [BrowserCookie] {
        guard isSafariInstalled else { return [] }

        let cookieData = try Data(contentsOf: safariCookiesFileURL)
        let parsedCookies = parseBinaryCookies(cookieData)
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))

        return parsedCookies.filter { cookie in
            let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return cookieDomain == normalizedHost
                || cookieDomain.hasSuffix(".\(normalizedHost)")
                || normalizedHost.hasSuffix(cookieDomain)
        }
    }

    // MARK: - Binary format parser

    private struct RawSafariCookie {
        let domain: String
        let name: String
        let value: String
        let path: String
        let flags: UInt32
    }

    private static func parseBinaryCookies(_ data: Data) -> [BrowserCookie] {
        guard data.count > 8 else { return [] }

        let magic = String(data: data.prefix(4), encoding: .ascii)
        guard magic == "cook" else { return [] }

        let pageCount = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        var pageOffsets: [Int] = []
        var offset = 8
        for _ in 0..<pageCount {
            guard offset + 4 <= data.count else { break }
            let pageOffset = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            pageOffsets.append(pageOffset)
            offset += 4
        }

        var cookies: [BrowserCookie] = []
        for pageOffset in pageOffsets {
            cookies.append(contentsOf: parseCookiePage(data: data, pageOffset: pageOffset))
        }
        return cookies
    }

    private static func parseCookiePage(data: Data, pageOffset: Int) -> [BrowserCookie] {
        guard pageOffset + 8 <= data.count else { return [] }

        let pageHeader = String(data: data.subdata(in: pageOffset..<pageOffset + 4), encoding: .ascii)
        guard pageHeader == "page" else { return [] }

        let cookieCount = Int(data.subdata(in: pageOffset + 4..<pageOffset + 8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        var cookieOffsets: [Int] = []
        var offset = pageOffset + 8
        for _ in 0..<cookieCount {
            guard offset + 4 <= data.count else { break }
            let cookieOffset = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            cookieOffsets.append(pageOffset + cookieOffset)
            offset += 4
        }

        return cookieOffsets.compactMap { parseSingleCookie(data: data, cookieOffset: $0) }
    }

    private static func parseSingleCookie(data: Data, cookieOffset: Int) -> BrowserCookie? {
        guard cookieOffset + 48 <= data.count else { return nil }

        let size = Int(data.subdata(in: cookieOffset..<cookieOffset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard size > 48, cookieOffset + size <= data.count else { return nil }

        func readUInt32(at position: Int) -> UInt32 {
            data.subdata(in: position..<position + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        }

        let flags = readUInt32(at: cookieOffset + 8)
        let domainOffset = Int(readUInt32(at: cookieOffset + 16))
        let nameOffset = Int(readUInt32(at: cookieOffset + 20))
        let pathOffset = Int(readUInt32(at: cookieOffset + 24))
        let valueOffset = Int(readUInt32(at: cookieOffset + 28))

        guard let domain = readNullTerminatedString(data: data, offset: cookieOffset + domainOffset),
              let name = readNullTerminatedString(data: data, offset: cookieOffset + nameOffset),
              let path = readNullTerminatedString(data: data, offset: cookieOffset + pathOffset),
              let value = readNullTerminatedString(data: data, offset: cookieOffset + valueOffset),
              !name.isEmpty else {
            return nil
        }

        let isSecure = (flags & 0x1) != 0
        let isHTTPOnly = (flags & 0x4) != 0

        return BrowserCookie(
            name: name,
            value: value,
            domain: domain,
            path: path.isEmpty ? "/" : path,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly,
            browserName: "Safari"
        )
    }

    private static func readNullTerminatedString(data: Data, offset: Int) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        var endIndex = offset
        while endIndex < data.count, data[endIndex] != 0 {
            endIndex += 1
        }
        return String(data: data.subdata(in: offset..<endIndex), encoding: .utf8)
    }
}
