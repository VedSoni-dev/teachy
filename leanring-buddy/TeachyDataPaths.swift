//
//  TeachyDataPaths.swift
//  leanring-buddy
//
//  Resolves on-disk Teachy data dirs. Prefers ~/.teachy; falls back to legacy
//  ~/.clicky so existing installs keep working.
//

import Foundation

enum TeachyDataPaths {
    /// Installed academy / custom course JSON.
    static var coursesDirectoryURL: URL {
        resolveDirectory(preferredRelativePath: ".teachy/courses", legacyRelativePath: ".clicky/courses")
    }

    /// OpenAPI / HTTP connection manifests.
    static var connectorsDirectoryURL: URL {
        resolveDirectory(preferredRelativePath: ".teachy/connectors", legacyRelativePath: ".clicky/connectors")
    }

    /// Teachy's memory: PROFILE.md, VOLATILE.md and the saved conversation window.
    /// New with the Brain, so there is no legacy ~/.clicky location to fall back to.
    nonisolated static var brainDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teachy/brain", isDirectory: true)
    }

    /// Human-facing path string for UI copy (always show the Teachy name).
    static var coursesDirectoryDisplayPath: String { "~/.teachy/courses" }

    static var connectorsDirectoryDisplayPath: String { "~/.teachy/connectors" }

    private static func resolveDirectory(preferredRelativePath: String, legacyRelativePath: String) -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let preferredURL = homeURL.appendingPathComponent(preferredRelativePath, isDirectory: true)
        let legacyURL = homeURL.appendingPathComponent(legacyRelativePath, isDirectory: true)

        if FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return preferredURL
    }
}
