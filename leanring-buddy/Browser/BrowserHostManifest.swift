//
//  BrowserHostManifest.swift
//  leanring-buddy
//
//  Where the browser helper and its Chrome "native messaging host" manifests
//  live, and what the manifest says. Pure: Foundation + CryptoKit, no AppKit.
//  The text it produces is byte-for-byte what scripts/install-chrome-host.sh
//  writes (the tests compare the two). Tested by scripts/tests/run_chrome_tests.sh.
//

import CryptoKit
import Foundation

nonisolated enum BrowserHostManifest {
    static let hostName = "com.teachy.browser"
    static let helperFileName = "teachy-browser-host"
    static let socketFileName = "browser.sock"

    /// The id Chrome derives from the public "key" in chrome-extension/manifest.json (unpacked / self-hosted builds).
    static let developmentExtensionID = "okfgkjagfedglgjgnfbcffnmopbgigem"
    /// Add the Chrome Web Store id here once the extension is published there (the store assigns its own).
    static let allowedExtensionIDs: [String] = [developmentExtensionID]

    struct Browser: Equatable {
        let name: String
        /// Folder under ~/Library/Application Support that holds NativeMessagingHosts.
        let supportFolder: String
        let bundleIdentifier: String
    }

    static let browsers: [Browser] = [
        Browser(name: "Chrome", supportFolder: "Google/Chrome", bundleIdentifier: "com.google.Chrome"),
        Browser(name: "Chrome Beta", supportFolder: "Google/Chrome Beta", bundleIdentifier: "com.google.Chrome.beta"),
        Browser(name: "Edge", supportFolder: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac"),
        Browser(name: "Brave", supportFolder: "BraveSoftware/Brave-Browser", bundleIdentifier: "com.brave.Browser"),
        Browser(name: "Arc", supportFolder: "Arc/User Data", bundleIdentifier: "company.thebrowser.Browser"),
        Browser(name: "Vivaldi", supportFolder: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi")
    ]

    // MARK: Paths

    /// ~/Library/Application Support (or a stand-in for tests).
    static func defaultSupportRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static func teachyFolder(root: URL) -> URL {
        root.appendingPathComponent("Teachy", isDirectory: true)
    }

    static func socketURL(root: URL) -> URL {
        teachyFolder(root: root).appendingPathComponent(socketFileName)
    }

    static func helperURL(root: URL) -> URL {
        teachyFolder(root: root).appendingPathComponent("browser-host", isDirectory: true).appendingPathComponent(helperFileName)
    }

    static func manifestURL(for browser: Browser, root: URL) -> URL {
        root.appendingPathComponent(browser.supportFolder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostName).json")
    }

    // MARK: Manifest text

    static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Extension ids are exactly 32 letters a-p.
    static func isValidExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0 >= "a" && $0 <= "p" }
    }

    static func manifestJSON(helperPath: String, extensionIDs: [String] = allowedExtensionIDs) -> String {
        let origins = extensionIDs.filter(isValidExtensionID).map { "\"chrome-extension://\($0)/\"" }.joined(separator: ", ")
        return """
        {
          "name": "\(hostName)",
          "description": "Lets the Teachy extension talk to the Teachy app on this Mac.",
          "path": "\(jsonEscaped(helperPath))",
          "type": "stdio",
          "allowed_origins": [\(origins)]
        }

        """
    }

    /// The id Chrome gives an extension whose manifest carries this public key (base64 DER):
    /// the first 16 bytes of its SHA-256, written with the letters a-p.
    static func extensionID(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let letters = Array("abcdefghijklmnop")
        var id = ""
        for byte in SHA256.hash(data: der).prefix(16) {
            id.append(letters[Int(byte >> 4)])
            id.append(letters[Int(byte & 0x0f)])
        }
        return id
    }

    // MARK: What is installed

    struct Installation: Equatable {
        /// The helper binary is where the manifests point.
        var helperPresent: Bool
        /// Browsers whose manifest exists and points at the helper.
        var browsersWithManifest: [String]

        var isInstalled: Bool { helperPresent && !browsersWithManifest.isEmpty }
    }

    static func installation(root: URL, fileManager: FileManager = .default) -> Installation {
        let helper = helperURL(root: root).path
        var ready: [String] = []
        for browser in browsers {
            let url = manifestURL(for: browser, root: root)
            guard let data = fileManager.contents(atPath: url.path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["name"] as? String == hostName,
                  let path = object["path"] as? String,
                  fileManager.isExecutableFile(atPath: path)
            else { continue }
            ready.append(browser.name)
        }
        return Installation(helperPresent: fileManager.isExecutableFile(atPath: helper), browsersWithManifest: ready)
    }

    /// Does what the install script does, for a helper that is already built: copies it into place
    /// and writes one manifest per browser. Returns the manifest files written.
    @discardableResult
    static func install(helperBinary: URL, root: URL, extensionIDs: [String] = allowedExtensionIDs, fileManager: FileManager = .default) throws -> [URL] {
        let destination = helperURL(root: root)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: teachyFolder(root: root).path)

        // Copy beside the target and rename over it, so a helper Chrome is running is never half-written.
        let staging = destination.appendingPathExtension("new")
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: helperBinary, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }

        let text = manifestJSON(helperPath: destination.path, extensionIDs: extensionIDs)
        var written: [URL] = []
        for browser in browsers {
            let url = manifestURL(for: browser, root: root)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    static func uninstall(root: URL, fileManager: FileManager = .default) {
        for browser in browsers {
            try? fileManager.removeItem(at: manifestURL(for: browser, root: root))
        }
        try? fileManager.removeItem(at: helperURL(root: root))
    }
}
