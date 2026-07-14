//
//  ComposioFrontmostAppMapping.swift
//  Maps the frontmost macOS app to a Composio toolkit slug.
//

import Foundation

struct ComposioFrontmostAppMatch: Equatable {
    let toolkitSlug: String
    let displayName: String
}

enum ComposioFrontmostAppMapping {
    private static let bundleIDToToolkit: [String: ComposioFrontmostAppMatch] = [
        "com.tinyspeck.slackmacgap": ComposioFrontmostAppMatch(toolkitSlug: "slack", displayName: "Slack"),
        "com.tinyspeck.slackmacgap.dev": ComposioFrontmostAppMatch(toolkitSlug: "slack", displayName: "Slack"),
        "com.notion.id": ComposioFrontmostAppMatch(toolkitSlug: "notion", displayName: "Notion"),
        "notion.id": ComposioFrontmostAppMatch(toolkitSlug: "notion", displayName: "Notion"),
        "com.figma.Desktop": ComposioFrontmostAppMatch(toolkitSlug: "figma", displayName: "Figma"),
        "com.github.GitHubClient": ComposioFrontmostAppMatch(toolkitSlug: "github", displayName: "GitHub"),
        "com.google.GoogleDrive": ComposioFrontmostAppMatch(toolkitSlug: "googledrive", displayName: "Google Drive"),
        "com.google.Drive": ComposioFrontmostAppMatch(toolkitSlug: "googledrive", displayName: "Google Drive"),
        "com.todoist.mac.Todoist": ComposioFrontmostAppMatch(toolkitSlug: "todoist", displayName: "Todoist"),
        "com.hnc.Discord": ComposioFrontmostAppMatch(toolkitSlug: "discord", displayName: "Discord"),
        "com.spotify.client": ComposioFrontmostAppMatch(toolkitSlug: "spotify", displayName: "Spotify"),
        "us.zoom.xos": ComposioFrontmostAppMatch(toolkitSlug: "zoom", displayName: "Zoom"),
        "com.microsoft.teams2": ComposioFrontmostAppMatch(toolkitSlug: "microsoft_teams", displayName: "Microsoft Teams"),
        "com.microsoft.teams": ComposioFrontmostAppMatch(toolkitSlug: "microsoft_teams", displayName: "Microsoft Teams"),
        "com.atlassian.jira": ComposioFrontmostAppMatch(toolkitSlug: "jira", displayName: "Jira"),
        "com.linear": ComposioFrontmostAppMatch(toolkitSlug: "linear", displayName: "Linear"),
        "com.apple.mail": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "com.google.Chrome": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "company.thebrowser.Browser": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "com.brave.Browser": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "com.microsoft.edgemac": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "com.apple.Safari": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
    ]

    private static let appNameToToolkit: [String: ComposioFrontmostAppMatch] = [
        "slack": ComposioFrontmostAppMatch(toolkitSlug: "slack", displayName: "Slack"),
        "notion": ComposioFrontmostAppMatch(toolkitSlug: "notion", displayName: "Notion"),
        "figma": ComposioFrontmostAppMatch(toolkitSlug: "figma", displayName: "Figma"),
        "github": ComposioFrontmostAppMatch(toolkitSlug: "github", displayName: "GitHub"),
        "linear": ComposioFrontmostAppMatch(toolkitSlug: "linear", displayName: "Linear"),
        "jira": ComposioFrontmostAppMatch(toolkitSlug: "jira", displayName: "Jira"),
        "discord": ComposioFrontmostAppMatch(toolkitSlug: "discord", displayName: "Discord"),
        "spotify": ComposioFrontmostAppMatch(toolkitSlug: "spotify", displayName: "Spotify"),
        "zoom": ComposioFrontmostAppMatch(toolkitSlug: "zoom", displayName: "Zoom"),
        "microsoft teams": ComposioFrontmostAppMatch(toolkitSlug: "microsoft_teams", displayName: "Microsoft Teams"),
        "teams": ComposioFrontmostAppMatch(toolkitSlug: "microsoft_teams", displayName: "Microsoft Teams"),
        "todoist": ComposioFrontmostAppMatch(toolkitSlug: "todoist", displayName: "Todoist"),
        "mail": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
        "gmail": ComposioFrontmostAppMatch(toolkitSlug: "gmail", displayName: "Gmail"),
    ]

    static func match(bundleIdentifier: String?, localizedAppName: String?) -> ComposioFrontmostAppMatch? {
        if let bundleIdentifier,
           let bundleMatch = bundleIDToToolkit[bundleIdentifier] {
            return bundleMatch
        }

        guard let localizedAppName else { return nil }
        let normalizedAppName = localizedAppName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedAppName.isEmpty { return nil }

        if let exactNameMatch = appNameToToolkit[normalizedAppName] {
            return exactNameMatch
        }

        for (appNameKeyword, toolkitMatch) in appNameToToolkit {
            if normalizedAppName.contains(appNameKeyword) {
                return toolkitMatch
            }
        }

        return nil
    }
}
