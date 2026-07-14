//
//  ChromiumBrowserCookieReader.swift
//  Reads and decrypts cookies from Chromium-based browsers (Chrome, Brave, Arc, Edge).
//

import CommonCrypto
import Foundation
import Security
import SQLite3

enum ChromiumBrowser: String, CaseIterable, Identifiable {
    case chrome
    case brave
    case arc
    case edge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        }
    }

    var applicationSupportFolderName: String {
        switch self {
        case .chrome: return "Google/Chrome"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .arc: return "Arc/User Data"
        case .edge: return "Microsoft Edge"
        }
    }

    var keychainServiceName: String {
        switch self {
        case .chrome: return "Chrome Safe Storage"
        case .brave: return "Brave Safe Storage"
        case .arc: return "Arc Safe Storage"
        case .edge: return "Microsoft Edge Safe Storage"
        }
    }

    var keychainAccountName: String {
        switch self {
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        }
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: applicationSupportDirectoryURL.path)
    }

    var applicationSupportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(applicationSupportFolderName)", isDirectory: true)
    }
}

struct BrowserCookie: Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let isSecure: Bool
    let isHTTPOnly: Bool
    let browserName: String
}

enum ChromiumBrowserCookieReaderError: LocalizedError {
    case browserNotInstalled(String)
    case keychainPasswordUnavailable(String)
    case cookieDatabaseUnavailable(String)
    case sqliteError(String)

    var errorDescription: String? {
        switch self {
        case .browserNotInstalled(let name): return "\(name) is not installed."
        case .keychainPasswordUnavailable(let detail): return "Could not read browser keychain entry: \(detail)"
        case .cookieDatabaseUnavailable(let detail): return "Cookie database unavailable: \(detail)"
        case .sqliteError(let detail): return "SQLite error: \(detail)"
        }
    }
}

enum ChromiumBrowserCookieReader {

    /// PBKDF2 PRF for Chromium cookie decryption (`kCCPRFHmacAlgSHA1` == 1).
    private static let chromiumPBKDF2PRFAlgorithm = CCPseudoRandomAlgorithm(1)

    static func installedBrowsers() -> [ChromiumBrowser] {
        ChromiumBrowser.allCases.filter(\.isInstalled)
    }

    /// Returns decrypted cookies whose domain matches `host` (e.g. github.com).
    static func cookies(matchingHost host: String, browser: ChromiumBrowser) throws -> [BrowserCookie] {
        guard browser.isInstalled else {
            throw ChromiumBrowserCookieReaderError.browserNotInstalled(browser.displayName)
        }

        let encryptionKey = try readChromiumEncryptionKey(browser: browser)
        let profileDirectories = try discoverProfileDirectories(browser: browser)
        var allCookies: [BrowserCookie] = []

        for profileDirectory in profileDirectories {
            let cookieDatabaseURL = profileDirectory.appendingPathComponent("Cookies")
            guard FileManager.default.fileExists(atPath: cookieDatabaseURL.path) else { continue }

            let temporaryDatabaseURL = try copyCookieDatabaseToTemporaryLocation(cookieDatabaseURL: cookieDatabaseURL)
            defer { try? FileManager.default.removeItem(at: temporaryDatabaseURL) }

            let profileCookies = try readCookiesFromDatabase(
                databaseURL: temporaryDatabaseURL,
                encryptionKey: encryptionKey,
                matchingHost: host,
                browserName: browser.displayName
            )
            allCookies.append(contentsOf: profileCookies)
        }

        return deduplicatedCookies(allCookies)
    }

    // MARK: - Keychain + decryption

    private static func readChromiumEncryptionKey(browser: ChromiumBrowser) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainServiceName,
            kSecAttrAccount as String: browser.keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var keychainItem: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &keychainItem)
        guard status == errSecSuccess,
              let passwordData = keychainItem as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw ChromiumBrowserCookieReaderError.keychainPasswordUnavailable(
                "\(browser.displayName) (\(status))"
            )
        }

        return try deriveChromiumEncryptionKey(password: password)
    }

    /// Chromium derives a 128-bit AES key via PBKDF2-HMAC-SHA1 (1003 rounds, salt "saltysalt").
    private static func deriveChromiumEncryptionKey(password: String) throws -> Data {
        let saltData = Data("saltysalt".utf8)
        var derivedKeyData = Data(repeating: 0, count: 16)

        let derivationStatus = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            guard let derivedKeyRawPointer = derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(kCCParamError)
            }
            return saltData.withUnsafeBytes { saltBytes in
                guard let saltRawPointer = saltBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return password.withCString { passwordPointer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPointer,
                        password.utf8.count,
                        saltRawPointer,
                        saltData.count,
                        chromiumPBKDF2PRFAlgorithm,
                        1003,
                        derivedKeyRawPointer,
                        16
                    )
                }
            }
        }

        guard derivationStatus == kCCSuccess else {
            throw ChromiumBrowserCookieReaderError.keychainPasswordUnavailable("PBKDF2 failed (\(derivationStatus))")
        }
        return derivedKeyData
    }

    private static func decryptChromiumCookieValue(_ encryptedData: Data, encryptionKey: Data) -> String? {
        if encryptedData.count < 4 {
            return String(data: encryptedData, encoding: .utf8)
        }

        let versionPrefix = String(data: encryptedData.prefix(3), encoding: .ascii)
        guard versionPrefix == "v10" || versionPrefix == "v11" else {
            return String(data: encryptedData, encoding: .utf8)
        }

        let ciphertext = encryptedData.dropFirst(3)
        let initializationVector = Data(repeating: 0x20, count: 16)

        var decryptedBuffer = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let cryptStatus = encryptionKey.withUnsafeBytes { keyBytes in
            initializationVector.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { cipherBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        encryptionKey.count,
                        ivBytes.baseAddress,
                        cipherBytes.baseAddress,
                        ciphertext.count,
                        &decryptedBuffer,
                        decryptedBuffer.count,
                        &decryptedLength
                    )
                }
            }
        }

        guard cryptStatus == kCCSuccess, decryptedLength > 0 else { return nil }
        return String(bytes: decryptedBuffer.prefix(decryptedLength), encoding: .utf8)
    }

    // MARK: - SQLite

    private static func discoverProfileDirectories(browser: ChromiumBrowser) throws -> [URL] {
        let userDataDirectory = browser.applicationSupportDirectoryURL
        var profileDirectories: [URL] = []

        let defaultProfile = userDataDirectory.appendingPathComponent("Default", isDirectory: true)
        if FileManager.default.fileExists(atPath: defaultProfile.path) {
            profileDirectories.append(defaultProfile)
        }

        let profileNames = try FileManager.default.contentsOfDirectory(atPath: userDataDirectory.path)
        for profileName in profileNames where profileName.hasPrefix("Profile ") {
            let profileURL = userDataDirectory.appendingPathComponent(profileName, isDirectory: true)
            profileDirectories.append(profileURL)
        }

        guard !profileDirectories.isEmpty else {
            throw ChromiumBrowserCookieReaderError.cookieDatabaseUnavailable("No profiles found")
        }
        return profileDirectories
    }

    private static func copyCookieDatabaseToTemporaryLocation(cookieDatabaseURL: URL) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-browser-cookies", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let destinationURL = temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")

        try FileManager.default.copyItem(at: cookieDatabaseURL, to: destinationURL)

        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: cookieDatabaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                let destinationSidecarURL = URL(fileURLWithPath: destinationURL.path + suffix)
                try? FileManager.default.copyItem(at: sidecarURL, to: destinationSidecarURL)
            }
        }

        return destinationURL
    }

    private static func readCookiesFromDatabase(
        databaseURL: URL,
        encryptionKey: Data,
        matchingHost host: String,
        browserName: String
    ) throws -> [BrowserCookie] {
        var databaseHandle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &databaseHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = databaseHandle else {
            throw ChromiumBrowserCookieReaderError.sqliteError("Could not open database")
        }
        defer { sqlite3_close(database) }

        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let hostPattern = "%\(normalizedHost)%"
        let query = """
            SELECT host_key, name, value, encrypted_value, path, is_secure, is_httponly
            FROM cookies
            WHERE host_key LIKE ? OR host_key LIKE ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let preparedStatement = statement else {
            throw ChromiumBrowserCookieReaderError.sqliteError(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(preparedStatement) }

        let dotHostPattern = "%.\(normalizedHost)%"
        sqlite3_bind_text(preparedStatement, 1, hostPattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(preparedStatement, 2, dotHostPattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var cookies: [BrowserCookie] = []
        while sqlite3_step(preparedStatement) == SQLITE_ROW {
            let domain = String(cString: sqlite3_column_text(preparedStatement, 0))
            let name = String(cString: sqlite3_column_text(preparedStatement, 1))

            let decryptedValue: String?
            if sqlite3_column_type(preparedStatement, 3) != SQLITE_NULL {
                let encryptedLength = sqlite3_column_bytes(preparedStatement, 3)
                if let encryptedBytes = sqlite3_column_blob(preparedStatement, 3), encryptedLength > 0 {
                    let encryptedData = Data(bytes: encryptedBytes, count: Int(encryptedLength))
                    decryptedValue = decryptChromiumCookieValue(encryptedData, encryptionKey: encryptionKey)
                } else {
                    decryptedValue = nil
                }
            } else if sqlite3_column_type(preparedStatement, 2) != SQLITE_NULL {
                decryptedValue = String(cString: sqlite3_column_text(preparedStatement, 2))
            } else {
                decryptedValue = nil
            }

            guard let cookieValue = decryptedValue, !cookieValue.isEmpty else { continue }

            let path = String(cString: sqlite3_column_text(preparedStatement, 4))
            let isSecure = sqlite3_column_int(preparedStatement, 5) == 1
            let isHTTPOnly = sqlite3_column_int(preparedStatement, 6) == 1

            cookies.append(BrowserCookie(
                name: name,
                value: cookieValue,
                domain: domain,
                path: path,
                isSecure: isSecure,
                isHTTPOnly: isHTTPOnly,
                browserName: browserName
            ))
        }

        return cookies
    }

    private static func deduplicatedCookies(_ cookies: [BrowserCookie]) -> [BrowserCookie] {
        var seenKeys = Set<String>()
        var uniqueCookies: [BrowserCookie] = []
        for cookie in cookies {
            let key = "\(cookie.domain)|\(cookie.name)|\(cookie.path)"
            if seenKeys.insert(key).inserted {
                uniqueCookies.append(cookie)
            }
        }
        return uniqueCookies
    }

    static func readDomainSummary(databaseURL: URL) -> (cookieCount: Int, domains: Set<String>) {
        var databaseHandle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &databaseHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database = databaseHandle else {
            return (0, [])
        }
        defer { sqlite3_close(database) }

        var domains = Set<String>()
        var domainStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT DISTINCT host_key FROM cookies LIMIT 200", -1, &domainStatement, nil) == SQLITE_OK,
           let preparedDomainStatement = domainStatement {
            defer { sqlite3_finalize(preparedDomainStatement) }
            while sqlite3_step(preparedDomainStatement) == SQLITE_ROW {
                let domain = String(cString: sqlite3_column_text(preparedDomainStatement, 0))
                domains.insert(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }
        }

        var cookieCount = 0
        var countStatement: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM cookies", -1, &countStatement, nil) == SQLITE_OK,
           let preparedCountStatement = countStatement {
            defer { sqlite3_finalize(preparedCountStatement) }
            if sqlite3_step(preparedCountStatement) == SQLITE_ROW {
                cookieCount = Int(sqlite3_column_int(preparedCountStatement, 0))
            }
        }

        return (cookieCount, domains)
    }
}
